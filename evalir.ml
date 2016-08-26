open Notfound
open Utility
open Proc

let lookup_fun = Tables.lookup Tables.fun_defs
let find_fun = Tables.find Tables.fun_defs

module Eval = struct
  open Ir

  exception EvaluationError of string
  exception Wrong

  let eval_error fmt : 'a =
    let error msg = raise (EvaluationError msg) in
      Printf.kprintf error fmt

  let db_connect : Value.t -> Value.database * string = fun db ->
    let driver = Value.unbox_string (Value.project "driver" db)
    and name = Value.unbox_string (Value.project "name" db)
    and args = Value.unbox_string (Value.project "args" db) in
    let params =
      (if args = "" then name
       else name ^ ":" ^ args)
    in
      Value.db_connect driver params

  let lookup_fun_def env f =
    match lookup_fun f with
    | None -> None
    | Some (finfo, _, None, location) ->
      begin
        match location with
        | `Server | `Unknown ->
          (* TODO: perhaps we should actually use env here - and make
             sure we only call this function when it is sufficiently
             small *)
          Some (`FunctionPtr (f, Value.empty_env))
        | `Client ->
          Some (`ClientFunction (Js.var_name_binder (f, finfo)))
      end

  let find_fun_def env f =
    val_of (lookup_fun_def env f)

  (* TODO: explicitly distinguish functions and variables in the
     IR so we don't have to do this check every time we look up a
     variable *)
  let lookup_var var env =
    if Lib.is_primitive_var var then Lib.primitive_stub_by_code var
    else
      match lookup_fun_def env var with
      | None ->
        Value.find var env
      | Some v -> v

   let serialize_call_to_client (continuation, handlers, name, arg) =
     Json.jsonize_call continuation handlers name arg

   let client_call : string -> Value.continuation -> Value.handlers -> Value.t list -> 'a =
     fun name cont hs args ->
       if not(Settings.get_value Basicsettings.web_mode) then
         failwith "Can't make client call outside web mode.";
       if not(Proc.singlethreaded()) then
         failwith "Remaining procs on server at client call!";
       Debug.print("Making client call to " ^ name);
(*        Debug.print("Call package: "^serialize_call_to_client (cont, name, args)); *)
       let call_package = Utility.base64encode
                            (serialize_call_to_client (cont, hs, name, args)) in
         Lib.print_http_response ["Content-type", "text/plain"] call_package;
         exit 0

  (** {0 Evaluation} *)
  let rec value env : Ir.value -> Value.t = function
    | `Constant `Bool b -> `Bool b
    | `Constant `Int n -> `Int n
    | `Constant `Char c -> `Char c
    | `Constant `String s -> Value.box_string s
    | `Constant `Float f -> `Float f
    | `Variable var -> lookup_var var env
(*
        begin
          match lookup_var var env with
            | Some v -> v
            | _      -> eval_error "Variable not found: %d" var
        end
*)
    | `Extend (fields, r) ->
        begin
          match opt_app (value env) (`Record []) r with
            | `Record fs ->
                (* HACK

                   Pre-pending the fields to r in this order shouldn't
                   be necessary but without the List.rev, deriving
                   somehow manages to serialise things in the wrong
                   order on the "Your Shopping Cart" page of the
                   winestore example. *)
                `Record (List.rev
                           (StringMap.fold
                              (fun label v fs ->
                                 if List.mem_assoc label fs then
                                   (* (label, value env v) :: (List.remove_assoc label fs) *)
                                   eval_error
                                     "Error adding fields: label %s already present" label
                                 else
                                   (label, value env v)::fs)
                              fields
                              []) @ fs)
(*                 `Record (StringMap.fold  *)
(*                            (fun label v fs -> *)
(*                               (label, value env v)::fs) *)
(*                            fields *)
(*                            fs) *)
            | _ -> eval_error "Error adding fields: non-record"
        end
    | `Project (label, r) ->
        begin
          match value env r with
            | `Record fields when List.mem_assoc label fields ->
                List.assoc label fields
            | _ -> eval_error "Error projecting label %s" label
        end
    | `Erase (labels, r) ->
        begin
          match value env r with
            | `Record fields when
                StringSet.for_all (fun label -> List.mem_assoc label fields) labels ->
                `Record (StringSet.fold (fun label fields -> List.remove_assoc label fields) labels fields)
            | _ -> eval_error "Error erasing labels {%s}" (String.concat "," (StringSet.elements labels))
        end
    | `Inject (label, v, t) -> `Variant (label, value env v)
    | `TAbs (_, v) -> value env v
    | `TApp (v, _) -> value env v
    | `XmlNode (tag, attrs, children) ->
        let children =
          List.fold_right
            (fun v children ->
               let v = value env v in
                 List.map Value.unbox_xml (Value.unbox_list v) @ children)
            children [] in
        let children =
          StringMap.fold
            (fun name v attrs ->
               Value.Attr (name, Value.unbox_string (value env v)) :: attrs)
            attrs children
        in
          Value.box_list [Value.box_xml (Value.Node (tag, children))]
    | `ApplyPure (f, args) ->
      Proc.atomically (fun () -> apply Value.toplevel_cont Value.toplevel_hs env (value env f, List.map (value env) args))
    | `Closure (f, v) ->
      let (finfo, _, z, location) = find_fun f in
      let z =
        match z with
        | None -> failwith ("Closure without environment variable: " ^ Ir.Show_value.show (`Closure (f, v)));
        | Some z -> z
      in
      begin
        match location with
        | `Server | `Unknown ->
          let r = value env v in
          let locals = Value.bind z (value env v, `Local) Value.empty_env in
          `FunctionPtr (f, locals)
        | `Client ->
          `ClientFunction (Js.var_name_binder (f, finfo))
      end
    | `Coerce (v, t) -> value env v

  and apply cont hs env : Value.t * Value.t list -> Proc.thread_result Lwt.t =
    function
    | `FunctionPtr (f, locals), ps ->
      let (_finfo, (xs, body), _z, _location) as def = find_fun f in
      let env = Value.shadow env ~by:locals in
      (* extend env with arguments *)
      let env = List.fold_right2 (fun x p -> Value.bind x (p, `Local)) xs ps env in
      computation env cont hs body
    | `PrimitiveFunction ("Send",_), [pid; msg] ->
        if Settings.get_value Basicsettings.web_mode && not (Settings.get_value Basicsettings.concurrent_server) then
           client_call "_SendWrapper" cont hs [pid; msg]
        else
          let pid = Value.unbox_int pid in
            (try
               Mailbox.send_message msg pid;
               Proc.awaken pid
             with
                 UnknownProcessID pid ->
                   (* FIXME: printing out the message might be more useful. *)
                   failwith("Couldn't deliver message because destination process has no mailbox."));
            apply_cont cont hs env (`Record [])
    | `PrimitiveFunction ("spawn",_), [func] ->
        if Settings.get_value Basicsettings.web_mode && not (Settings.get_value Basicsettings.concurrent_server) then
           client_call "_spawnWrapper" cont hs [func]
        else
          begin
            let var = Var.dummy_var in
            let delim = [(`Local, var, Value.empty_env,
                          ([], `Apply (`Variable var, [])))] in
	    let cont' = Value.append_delim_cont delim Value.toplevel_cont in
            let new_pid = Proc.create_process false (fun () -> apply_cont cont' Value.toplevel_hs env func) in
            apply_cont cont hs env (`Int new_pid)
          end
    | `PrimitiveFunction ("spawnAngel",_), [func] ->
        if Settings.get_value Basicsettings.web_mode && not (Settings.get_value Basicsettings.concurrent_server) then
           client_call "_spawnWrapper" cont hs [func]
        else
          begin
            (* if Settings.get_value Basicsettings.web_mode then *)
            (*   failwith("Can't spawn at the server in web mode."); *)
            let var = Var.dummy_var in
            let delim = [(`Local, var, Value.empty_env,
                          ([], `Apply (`Variable var, [])))] in
	    let cont' = Value.append_delim_cont delim Value.toplevel_cont in
            let new_pid = Proc.create_process true (fun () -> apply_cont cont' Value.toplevel_hs env func) in
            apply_cont cont hs env (`Int new_pid)
          end
    | `PrimitiveFunction ("recv",_), [] ->
        (* If there are any messages, take the first one and apply the
           continuation to it.  Otherwise, block the process (put its
           continuation in the blocked_processes table) and let the
           scheduler choose a different thread.  *)
(*         if (Settings.get_value Basicsettings.web_mode) then *)
(*             Debug.print("receive in web server mode--not implemented."); *)
        if Settings.get_value Basicsettings.web_mode && not (Settings.get_value Basicsettings.concurrent_server) then
           client_call "_recvWrapper" cont hs []
        else
        begin match Mailbox.pop_message () with
            Some message ->
              Debug.print("delivered message.");
              apply_cont cont hs env message
          | None ->
              let recv_frame = Value.expr_to_contframe
                env (Lib.prim_appln "recv" [])
              in
              Proc.block (fun () -> apply_cont (Value.append_cont_frame recv_frame cont) hs env (`Record []))
        end
    (* Session stuff *)
    | `PrimitiveFunction ("new", _), [] ->
      let apid = Session.new_access_point () in
        apply_cont cont hs env (`Int apid)
    | `PrimitiveFunction ("accept", _), [ap] ->
      let apid = Value.unbox_int ap in
      let (c, d), blocked = Session.accept apid in
      Debug.print ("accepting: (" ^ string_of_int c ^ ", " ^ string_of_int d ^ ")");
        if blocked then
          let accept_frame =
              Value.expr_to_contframe env
                (`Return (`Extend (StringMap.add "1" (`Constant (`Int c))
                                     (StringMap.add "2" (`Constant (`Int d))
                                        StringMap.empty), None)))
            in
              (* block my end of the channel *)
              Session.block c (Proc.get_current_pid ());
              Proc.block (fun () -> apply_cont (Value.append_cont_frame accept_frame cont) hs env (`Record []))
        else
          begin
            begin
              (* unblock the other end of the channel *)
              match Session.unblock d with
              | Some pid -> Proc.awaken pid
              | None     -> assert false
            end;
            apply_cont cont hs env (Value.box_pair
                                   (Value.box_int c)
                                   (Value.box_int d))
          end
    | `PrimitiveFunction ("request", _), [ap] ->
      let apid = Value.unbox_int ap in
      let (c, d), blocked = Session.request apid in
      Debug.print ("requesting: (" ^ string_of_int c ^ ", " ^ string_of_int d ^ ")");
        if blocked then
          let request_frame =
              Value.expr_to_contframe env
                (`Return (`Extend (StringMap.add "1" (`Constant (`Int c))
                                     (StringMap.add "2" (`Constant (`Int d))
                                        StringMap.empty), None)))
            in
              (* block my end of the channel *)
              Session.block c (Proc.get_current_pid ());
              Proc.block (fun () -> apply_cont (Value.append_cont_frame request_frame cont) hs env (`Record []))
        else
          begin
            begin
              (* unblock the other end of the channel *)
              match Session.unblock d with
              | Some pid -> Proc.awaken pid
              | None     -> assert false
            end;
            apply_cont cont hs env (Value.box_pair
                                   (Value.box_int c)
                                   (Value.box_int d))
          end
    | `PrimitiveFunction ("send", _), [v; chan] ->
      Debug.print ("sending: " ^ Value.string_of_value v ^ " to channel: " ^ Value.string_of_value chan);
      let (outp, _) = Session.unbox_chan chan in
      Session.send v outp;
      begin
        match Session.unblock outp with
          Some pid -> Proc.awaken pid
        | None     -> ()
      end;
      apply_cont cont hs env chan
    | `PrimitiveFunction ("receive", _), [chan] ->
      begin
        Debug.print("receiving from channel: " ^ Value.string_of_value chan);
        let (out', in') = Session.unbox_chan' chan in
        let inp = in' in
          match Session.receive inp with
          | Some v ->
            Debug.print ("grabbed: " ^ Value.string_of_value v);
            apply_cont cont hs env (Value.box_pair v chan)
          | None ->
            let grab_frame =
              Value.expr_to_contframe env (Lib.prim_appln "receive" [`Extend (StringMap.add "1" (`Constant (`Int out'))
                                                                                (StringMap.add "2" (`Constant (`Int in'))
                                                                                   StringMap.empty), None)])
            in
              Session.block inp (Proc.get_current_pid ());
              Proc.block (fun () -> apply_cont (Value.append_cont_frame grab_frame cont) hs env (`Record []))
      end
    | `PrimitiveFunction ("link", _), [chanl; chanr] ->
      let unblock p =
        match Session.unblock p with
        | Some pid -> (*Debug.print("unblocked: "^string_of_int p); *)
                      Proc.awaken pid
        | None     -> () in
      Debug.print ("linking channels: " ^ Value.string_of_value chanl ^ " and: " ^ Value.string_of_value chanr);
      let (out1, in1) = Session.unbox_chan chanl in
      let (out2, in2) = Session.unbox_chan chanr in
      (* HACK *)
      let end_bang = `Variable (Env.String.lookup (val_of !Lib.prelude_nenv) "makeEndBang") in
        Session.fuse (out1, in1) (out2, in2);
        unblock out1;
        unblock out2;
        apply cont hs env (value env end_bang, [])
    (*****************)
    | `PrimitiveFunction (n,None), args ->
        apply_cont cont hs env (Lib.apply_pfun n args)
    | `PrimitiveFunction (n,Some code), args ->
        apply_cont cont hs env (Lib.apply_pfun_by_code code args)
    | `ClientFunction name, args   -> client_call name cont hs args
    | `ShallowContinuation (delim, cont', hs'), [p] ->
       (** *)
       let cont = Value.append_delim_cont delim cont in
       apply_cont (cont' @ cont) (hs' @ hs) env p
    | `DeepContinuation (cont', hs'), [p] ->
       apply_cont (cont' @ cont) (hs' @  hs) env p
    | `Continuation (cont, hs), [p] -> apply_cont cont hs env p
    | `Continuation _,       _    ->
        eval_error "Continuation applied to multiple (or zero) arguments"
    | (v,vs)                      -> eval_error "Application of non-function: %s" (Value.string_of_value v)
  and apply_cont cont hs env v =
    Proc.yield (fun () -> apply_cont' cont hs env v)
  and apply_cont' cont hs env v : Proc.thread_result Lwt.t =
    match cont, hs with
    | [] :: conts, h :: hs ->
      invoke_return_clause conts hs env h v
    | [], [] ->
      Proc.finish (env, v)
    | [] :: conts, [] -> apply_cont conts hs env v
    | (frame :: delim) :: conts, _ ->
      let (scope, var, locals, comp) = frame in
      let env = Value.bind var (v, scope) (Value.shadow env ~by:locals) in
      let conts = delim :: conts in
      computation env conts hs comp
    | _   -> failwith ("evalir.ml: apply_cont: Edge case: Ooops, what happened?")
  and computation env cont hs (bindings, tailcomp) : Proc.thread_result Lwt.t =
    match bindings with
      | [] -> tail_computation env cont hs tailcomp
      | b::bs -> match b with
        | `Let ((var, _) as b, (_, tc)) ->
              let locals = Value.localise env var in
              let contf  = Value.make_cont_frame (Var.scope_of_binder b) var locals (bs, tailcomp) in
              let cont   = Value.append_cont_frame contf cont in
              tail_computation env cont hs tc
          (* function definitions are stored in the global fun map *)
          | `Fun _ ->
            computation env cont hs (bs, tailcomp)
          | `Rec _ ->
            computation env cont hs (bs, tailcomp)
          | `Alien _ ->
            computation env cont hs (bs, tailcomp)
          | `Module _ -> failwith "Not implemented interpretation of modules yet"
  and tail_computation env cont hs : Ir.tail_computation -> Proc.thread_result Lwt.t = function
    (* | `Return (`ApplyPure _ as v) -> *)
    (*   let w = (value env v) in *)
    (*     Debug.print ("ApplyPure"); *)
    (*     Debug.print ("  value term: " ^ Show.show Ir.show_value v); *)
    (*     Debug.print ("  cont: " ^ Value.string_of_cont cont); *)
    (*     Debug.print ("  value: " ^ Value.string_of_value w); *)
    (*     apply_cont cont env w *)
    | `Return v      -> apply_cont cont hs env (value env v)
    | `Apply (f, ps) -> apply cont hs env (value env f, List.map (value env) ps)
    | `Special s     -> special env cont hs s
    | `Case (v, cases, default) ->
        begin match value env v with
           | `Variant (label, _) as v ->
               (match StringMap.lookup label cases, default, v with
                  | Some ((var,_), c), _, `Variant (_, v)
                  | _, Some ((var,_), c), v ->
                      computation (Value.bind var (v, `Local) env) cont hs c
                  | None, _, #Value.t -> eval_error "Pattern matching failed on %s" label 
                  | _ -> assert false (* v not a variant *))
           | _ -> eval_error "Case of non-variant"
        end
    | `If (c,t,e)    ->
        computation env cont hs
          (match value env c with
             | `Bool true     -> t
             | `Bool false    -> e
             | _              -> eval_error "Conditional was not a boolean")
  and special env cont hs : Ir.special -> Proc.thread_result Lwt.t = function
    | `Wrong _                    -> raise Wrong
    | `Database v                 -> apply_cont cont hs env (`Database (db_connect (value env v)))
    | `Table (db, name, (readtype, _, _)) ->
      begin
        (* OPTIMISATION: we could arrange for concrete_type to have
           already been applied here *)
        match value env db, value env name, (TypeUtils.concrete_type readtype) with
          | `Database (db, params), name, `Record row ->
            apply_cont cont hs env (`Table ((db, params), Value.unbox_string name, row))
          | _ -> eval_error "Error evaluating table handle"
      end
    | `Query (range, e, _t) ->
       let range =
         match range with
         | None -> None
         | Some (limit, offset) ->
            Some (Value.unbox_int (value env limit), Value.unbox_int (value env offset)) in
       begin
         match Query.compile env (range, e) with
         | None -> computation env cont hs e
         | Some (db, q, t) ->
            let (fieldMap, _, _), _ =
              Types.unwrap_row(TypeUtils.extract_row t) in
            let fields =
              StringMap.fold
                (fun name t fields ->
                 match t with
                 | `Present t -> (name, t)::fields
                 | `Absent -> assert false
                 | `Var _ -> assert false)
                fieldMap
                []
            in
            apply_cont cont hs env (Database.execute_select fields q db)
       end
      (* TODO: Is this refactoring valid?
      let result =
        match Query.compile env (range, e) with
          | None -> computation env cont hs e
          | Some (db, q, t) ->
            let (fieldMap, _, _), _ =
              Types.unwrap_row(TypeUtils.extract_row t) in
            let fields =
              StringMap.fold
                (fun name t fields ->
                  match t with
                    | `Present t -> (name, t)::fields
                    | `Absent -> assert false
                    | `Var _ -> assert false)
                fieldMap
                []
            in
              Database.execute_select fields q db
      in
        apply_cont cont hs env result
       *)
    | `Update ((xb, source), where, body) ->
      let db, table, field_types =
        match value env source with
          | `Table ((db, _), table, (fields, _, _)) ->
            db, table, (StringMap.map (function
                                        | `Present t -> t
                                        | _ -> assert false) fields)
          | _ -> assert false in
      let update_query =
        Query.compile_update db env ((Var.var_of_binder xb, table, field_types), where, body) in
      let () = ignore (Database.execute_command update_query db) in
        apply_cont cont hs env (`Record [])
    | `Delete ((xb, source), where) ->
      let db, table, field_types =
        match value env source with
          | `Table ((db, _), table, (fields, _, _)) ->
            db, table, (StringMap.map (function
                                        | `Present t -> t
                                        | _ -> assert false) fields)
          | _ -> assert false in
      let delete_query =
        Query.compile_delete db env ((Var.var_of_binder xb, table, field_types), where) in
      let () = ignore (Database.execute_command delete_query db) in
        apply_cont cont hs env (`Record [])
    | `CallCC f ->
       apply cont hs env (value env f, [`Continuation (cont, hs)])
    (* Handlers *)
    | `Handle (v, cases, spec) ->
       let hs = (env, cases, spec) :: hs in       
       let cont = [] :: cont in
       let comp = value env v in
       apply cont hs env (comp, [])
    | `DoOperation (name, v, t) ->
       let vs = List.map (value env) v in
       handle env cont hs (name,vs)
    (* Session stuff *)
    | `Select (name, v) ->
      let chan = value env v in
      Debug.print ("selecting: " ^ name ^ " from: " ^ Value.string_of_value chan);
      let (outp, _) = Session.unbox_chan chan in
      Session.send (Value.box_string name) outp;
      begin
        match Session.unblock outp with
          Some pid -> Proc.awaken pid
        | None     -> ()
      end;
      apply_cont cont hs env chan
    | `Choice (v, cases) ->
      begin
        let chan = value env v in
        Debug.print("choosing from: " ^ Value.string_of_value chan);
        let (out', in') = Session.unbox_chan' chan in
        let inp = in' in
          match Session.receive inp with
          | Some v ->
            Debug.print ("chose: " ^ Value.string_of_value v);
            let label = Value.unbox_string v in
              begin
                match StringMap.lookup label cases with
                | Some ((var,_), body) ->
                  computation (Value.bind var (chan, `Local) env) cont hs body
                | None -> eval_error "Choice pattern matching failed"
              end
          | None ->
            let choice_frame =
              Value.expr_to_contframe env (`Special (`Choice (v, cases)))
            in
            let cont = Value.append_cont_frame choice_frame cont in
              Session.block inp (Proc.get_current_pid ());
              Proc.block (fun () -> apply_cont cont hs env (`Record []))
      end
  (*****************)
  and handle env cont hs (opname, vs) =
    (** handle operations, forwarding appropriately, where
        [cont'] and [hs'] are reversed stacks of
        delimited continuations and handlers
        used for restoring the stacks when [k] is invoked  *)
    let rec handle' (cont', hs') =
      function
      | delim :: cont, (henv, h, spec) :: hs ->
         let cont' = delim :: cont' in
         let hs' = (henv, h, spec) :: hs' in
         begin
           match StringMap.lookup opname h with	    
	   | Some (kb, (var, _), comp) ->
	      let k = if HandlerUtils.IrHandler.is_shallow spec then
		  `ShallowContinuation (delim, List.rev (List.tl cont'), List.rev (List.tl hs'))
		else
		  `DeepContinuation (List.rev cont', List.rev hs')
	      in
              let henv =
                match kb with
                | `Effect kb -> Value.bind (Var.var_of_binder kb) (k, `Local) henv
                | _ -> henv
              in
	      computation (Value.bind var (Value.box vs, `Local) henv) cont hs comp
           | None ->
              Debug.print ("Forwarding: " ^ opname);
              handle' (cont', hs') (cont, hs)              
         end
      | _, [] -> eval_error "Unhandled operation: %s" opname
    in
    handle' ([], []) (cont, hs)
  and invoke_return_clause cont hs env (henv, h, _) v =
    match StringMap.lookup "Return" h with
    | Some (_, (var, _), comp) -> computation (Value.bind var (v, `Local) henv) cont hs comp
    | None -> eval_error "Pattern matching failed on Return"      

  let eval : Value.env -> program -> Proc.thread_result Lwt.t =
    fun env ->
    computation env Value.toplevel_cont Value.toplevel_hs
end

let run_program_with_cont : Value.continuation -> Value.env -> Ir.program ->
  (Value.env * Value.t) =
  fun cont env program ->
  let hs = Value.toplevel_hs in
    try (
      Proc.run (fun () -> Eval.computation env cont hs program)
      (* TODO: Figure out whether the handler stack should be an input parameter *)
    ) with
      | NotFound s -> failwith ("Internal error: NotFound " ^ s ^
                                   " while interpreting.")

let run_program : Value.env -> Ir.program -> (Value.env * Value.t) =
  fun env program ->
    try (
      Proc.run (fun () -> Eval.eval env program)
    ) with
      | NotFound s -> failwith ("Internal error: NotFound " ^ s ^
                                   " while interpreting.")
      | Not_found  -> failwith ("Internal error: Not_found while interpreting.")

let run_defs : Value.env -> Ir.binding list -> Value.env =
  fun env bs ->
    let env, _value =
      run_program env (bs, `Return(`Extend(StringMap.empty, None))) in
      env

(** [apply_cont_toplevel cont env v] applies a continuation to a value
    and returns the result. Finishing the main thread normally comes
    here immediately. *)
let apply_cont_toplevel cont env v =
  try snd (Proc.run (fun () -> Eval.apply_cont cont Value.toplevel_hs env v))
  with
    | NotFound s -> failwith ("Internal error: NotFound " ^ s ^
                                " while interpreting.")
let apply_with_cont cont env (f, vs) =
  try snd (Proc.run (fun () -> Eval.apply cont Value.toplevel_hs env (f, vs)))
  with
    | NotFound s -> failwith ("Internal error: NotFound " ^ s ^
                                " while interpreting.")

let apply_toplevel env (f, vs) =
  try snd (Proc.run (fun () -> Eval.apply Value.toplevel_cont Value.toplevel_hs env (f, vs)))
  with
    | NotFound s -> failwith ("Internal error: NotFound " ^ s ^
                                " while interpreting.")

let eval_toplevel env program =
  try snd (Proc.run (fun () -> Eval.eval env program))
  with
    | NotFound s -> failwith ("Internal error: NotFound " ^ s ^
                                " while interpreting.")

let eval_fun env f =
  Eval.find_fun_def env f
