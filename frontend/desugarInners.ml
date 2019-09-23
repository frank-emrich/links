open Links_core

open Utility
open Operators
open SourceCode.WithPos
open Sugartypes

(* Recursive functions must be used monomorphically inside their
   function bodies (unless annotated with a polymorphic type), but
   they may still be used polymorphically outside (after having been
   generalised). This pass unifies the inner and outer types of
   functions, which is necessary for converting to the IR, which
   stores a single type for each recursive function.
*)

let internal_error message = Errors.InternalError { filename = "desugarInners"; message }

(** Rewrite our list of type arguments from using the inner type to the outer
   one.

   qs represents the quantifier set of the outer type, and tyargs the type
   arguments for the inner type. extras defines the mapping between them.

   For each quantifier, we inspect its corresponding value in extras. If it is
   [Some], then we use the pre-existing type argument at that index.

   If the corresponding extra argument is [None], there is no suitable type
   argument, and so we try to determine an appropriate alternative.

   If we are within the function whose call we are fixing (determined by
   in_fun), then we can use its type arguments (as they will be in
   scope). Otherwise, it is impossible to know what type to use (without running
   the type checker again), and so we just give up and use a flexible type
   variable.

   This extra mapping is generated by the [Funs] case of typeSugar.ml *)
let rec add_extras in_fun qs extras tyargs =
  match qs, extras with
  | [], [] -> []
  | q::qs, None::extras ->
     let q = if in_fun then
               Types.type_arg_of_quantifier q
             else
               let open CommonTypes.PrimaryKind in
               match q with
               | _, (Type, sk) -> `Type (Types.fresh_type_variable sk)
               | _, (Row, sk) -> `Row (Types.make_empty_open_row sk)
               | _, (Presence, sk) -> `Presence (Types.fresh_presence_variable sk)
     in q :: add_extras in_fun qs extras tyargs
  | _::qs, Some i::extras -> List.nth tyargs i :: add_extras in_fun qs extras tyargs
  | _, _ -> raise (internal_error "Mismatch in number of quantifiers and type arguments")

let freeze = function
  | Var v -> FreezeVar v
  | Section s -> FreezeSection s
  | FreezeVar _ | FreezeSection _ as e -> e
  | _ -> raise (internal_error "Unfreezable node")

(** Attempt to patch up all references to recursive functions.

   We take any reference to recursive functions (as a variable, section or
   infix/unary operator), along with any type arguments which may be applied to
   that function, and attempt to fix it up using {!add_extras} to be consistent
   with the outer type. *)
class desugar_inners env =
object (o : 'self_type)
  inherit (TransformSugar.transform env) as super

  val extra_env = StringMap.empty

  (* Acts as a stack of which recursive function bodies we are currently
     visiting. This allows us to determine which type variables are currently
     in-scope or not. *)
  val visiting_funs = StringSet.empty

  method with_extra_env env =
    {< extra_env = env >}

  method with_visiting funs = {< visiting_funs = funs>}

  method add_extras name tyargs =
    let tyvars, extras = StringMap.find name extra_env in
    let in_fun = StringSet.mem name visiting_funs in
    let tyargs = add_extras in_fun tyvars extras tyargs in
    tyargs

  method bind f tyvars extras =
    {< extra_env = StringMap.add f (tyvars, extras) extra_env >}

  method unbind f =
    {< extra_env = StringMap.remove f extra_env >}

  method! phrasenode = function
    | (Var name as e)
    | (FreezeVar name as e)
    | (Section (Section.Name name) as e)
    | (FreezeSection (Section.Name name) as e)
         when StringMap.mem name extra_env ->
       let tyargs = o#add_extras name [] in
       let o = o#unbind name in
       let (o, e, t) = o#phrasenode (tappl (freeze e, tyargs)) in
       (o#with_extra_env extra_env, e, t)
    | TAppl ({node=Var name;_} as p, tyargs)
    | TAppl ({node=FreezeVar name;_} as p, tyargs)
    | TAppl ({node=Section (Section.Name name);_} as p, tyargs)
    | TAppl ({node=FreezeSection (Section.Name name);_} as p, tyargs)
         when StringMap.mem name extra_env ->
        let tyargs = o#add_extras name (List.map (snd ->- val_of) tyargs) in
        let o = o#unbind name in
        let (o, e, t) = o#phrasenode (tappl' (SourceCode.WithPos.map ~f:freeze p, tyargs)) in
        (o#with_extra_env extra_env, e, t)
    | InfixAppl ((tyargs, BinaryOp.Name name), e1, e2) when StringMap.mem name extra_env ->
        let tyargs = o#add_extras name tyargs in
          super#phrasenode (InfixAppl ((tyargs, BinaryOp.Name name), e1, e2))
    | UnaryAppl ((tyargs, UnaryOp.Name name), e) when StringMap.mem name extra_env ->
        let tyargs = o#add_extras name tyargs in
          super#phrasenode (UnaryAppl ((tyargs, UnaryOp.Name name), e))
    (* HACK: manage the lexical scope of extras *)
    | Spawn _ as e ->
        let (o, e, t) = super#phrasenode e in
          (o#with_extra_env extra_env, e, t)
    | Escape _ as e ->
        let (o, e, t) = super#phrasenode e in
          (o#with_extra_env extra_env, e, t)
    | Block _ as e ->
        let (o, e, t) = super#phrasenode e in
          (o#with_extra_env extra_env, e, t)
    | e -> super#phrasenode e

  method! funlit =
    (* HACK: manage the lexical scope of extras *)
    fun inner_mb lam ->
    let (o, lam, t) = super#funlit inner_mb lam in
    (o#with_extra_env extra_env, lam, t)

  method! bindingnode = function
    | Funs defs ->
        (* put the outer bindings in the environment *)
        let o, defs = o#rec_activate_outer_bindings defs in

        (* put the extras in the environment *)
        let o =
          List.fold_left
            (fun o {node={ rec_binder = bndr; rec_definition = ((tyvars, dt_opt), _); _ }; _ } ->
               match dt_opt with
                 | Some (_, extras) -> o#bind (Binder.to_name bndr) tyvars extras
                 | None -> assert false
            )
            o defs in

        (* unify inner and outer types for each def *)
        let (o, defs) =
          let rec list o =
            function
              | [] -> (o, [])
              | {node={ rec_binder = bndr;
                   rec_definition = ((tyvars, Some (_inner, extras)), lam);
                   _ } as fn; pos} :: defs ->
                 let outer = Binder.to_type bndr in
                 let (o, defs) = list o defs in
                 let extras = List.map (fun _ -> None) extras in
                 (o, make ~pos { fn with rec_definition = ((tyvars, Some (outer, extras)), lam) } :: defs)
              | _ -> assert false
          in
            list o defs in

        (* transform the function bodies *)
        let (o, defs) =
          let outer_tyvars = o#backup_quantifiers in
          let rec list o =
            function
            | [] -> (o, [])
            | {node={ rec_binder; rec_definition = ((tyvars, Some (inner, extras)), lam); _ } as fn; pos} :: defs ->
               let o = o#with_visiting (StringSet.add (Binder.to_name rec_binder) visiting_funs) in
               let (o, tyvars) = o#quantifiers tyvars in
               let (o, inner) = o#datatype inner in
               let inner_effects = TransformSugar.fun_effects inner (fst lam) in
               let (o, lam, _) = o#funlit inner_effects lam in
               let o = o#restore_quantifiers outer_tyvars in
               let o = o#with_visiting visiting_funs in

               let (o, defs) = list o defs in
               (o, make ~pos
                     { fn with
                       rec_definition = ((tyvars, Some (inner, extras)), lam);
                       rec_frozen = true } :: defs)
            | _ :: _ -> assert false
          in list o defs
        in

        (*
           It is important to explicitly remove the extras from the
           environment as any existing functions with the same name
           will now be shadowed by the functions defined in this
           binding - and hence will not need any extra type variables
           adding.
        *)
        (* remove the extras from the environment *)
        let o =
          List.fold_left
            (fun o fn -> o#unbind (Binder.to_name fn.node.rec_binder))
            o defs
        in
          (o, (Funs defs))
    | b -> super#bindingnode b

  method! binder =
    fun bndr ->
    let (o, bndr) = super#binder bndr in
    (* avoid accidentally capturing type applications through shadowing *)
    let o = o#unbind (Binder.to_name bndr) in
    (o, bndr)
end

let desugar_inners env = ((new desugar_inners env) : desugar_inners :> TransformSugar.transform)

let desugar_program : TransformSugar.program_transformer =
  fun env program -> snd3 ((desugar_inners env)#program program)

let desugar_sentence : TransformSugar.sentence_transformer =
  fun env sentence -> snd ((desugar_inners env)#sentence sentence)

let has_no_inners =
object
  inherit SugarTraversals.predicate as super

  val has_no_inners = true
  method satisfied = has_no_inners

  method! bindingnode = function
    | Funs defs ->
        {< has_no_inners =
            List.for_all
              (fun {node={ rec_definition = ((_, dt_opt), _); _ }; _ } ->
                 match dt_opt with
                    | None -> assert false
                    | Some (_inner, extras) ->
                         List.for_all (function
                                         | None -> true
                                         | Some _ -> false) extras)
              defs >}
    | b -> super#bindingnode b
end
