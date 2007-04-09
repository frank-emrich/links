(*pp deriving *)
open Num
open List
open Utility
open Show
open Pickle

type lexpos = Lexing.position 
module Typeable_lexpos = Typeable.Primitive_typeable(struct type t = lexpos end)

module Eq_lexpos : Eq.Eq with type a = lexpos = 
struct
  type a = lexpos
  let eq = (==)
end

let print_digest_junk = Settings.add_bool("print_digest_junk", false, `User)

module LexposType = struct type a = lexpos let tname = "Syntax.lexpos" end
module Show_lexpos = Show_unprintable (LexposType)
(*module Pickle_lexpos = Pickle_unpicklable (LexposType)*)

module Pickle_lexpos : Pickle with type a = lexpos = Pickle.Pickle_defaults(
  struct
    type a = lexpos
    let pickle buffer e = ()
    and unpickle stream = Lexing.dummy_pos 
  end)

open Shelve
module Shelve_lexpos : Shelve with type a = lexpos = Shelve.Shelve_defaults(
  struct
    type a = lexpos
    module Eq = Eq_lexpos
    module Typeable = Typeable_lexpos
    let shelve _ = failwith "lexpos shelve nyi"
  end
)

type position = lexpos *  (* source line: *) string 
                  * (* expression source: *) string
    deriving (Typeable, Show, Pickle, Shelve, Eq)

let dummy_position = Lexing.dummy_pos, "<dummy>", "<dummy>"
    
exception ASTSyntaxError of position * string

type location = [`Client | `Server | `Native | `Unknown]
    deriving (Eq, Typeable, Show, Pickle, Shelve)

type label = string
    deriving (Eq, Typeable, Show, Pickle, Shelve)
    (* Q: Can I write my own show for these? I want to base64 it *)

type comparison = [`Less | `LessEq | `Equal | `NotEq]
    deriving (Eq, Typeable, Show, Pickle, Shelve)

let string_of_comparison = function
  | `Less   -> "<"
  | `LessEq -> "<="
  | `Equal  -> "=="
  | `NotEq  -> "<>"

type 'data expression' =
  | Define of (string * 'data expression' * location * 'data)
  | TypeDecl of (string * int list * Types.datatype * 'data)
  | Boolean of (bool * 'data)
  | Integer of (num * 'data)
  | Char of (char * 'data)
  | String of (string * 'data)
  | Float of (float * 'data)
  | Variable of (string * 'data)

  | Apply of ('data expression' * 'data expression' * 'data)
  | Condition of ('data expression' * 'data expression' * 'data expression' * 
                    'data)
  | Comparison of ('data expression' * comparison * 'data expression' * 'data)
  | Abstr of (string * 'data expression' * 'data)
  | Let of (string * 'data expression' * 'data expression' * 'data)
  | Rec of ((string * 'data expression' * Types.datatype option) list 
            * 'data expression' * 'data)
  | Xml_node of (string * ((string * 'data expression') list) * 
                   ('data expression' list) * 'data)
  | Record_intro of (('data expression') stringmap * ('data expression') option 
                     * 'data)
  | Record_selection of (string * string * string * 'data expression' * 
                           'data expression' * 'data)
  | Project of ('data expression' * string * 'data)
  | Erase of ('data expression' * string * 'data)
  | Variant_injection of (string * 'data expression' * 'data)
  | Variant_selection of ('data expression' * 
                            string * string * 'data expression' * 
                            string * 'data expression' * 'data)
  | Variant_selection_empty of ('data expression' * 'data)
  | Nil of ('data)
  | List_of of ('data expression' * 'data)
  | Concat of ('data expression' * 'data expression' * 'data)
  | For of ('data expression' * string * 'data expression' * 'data)
  | Database of ('data expression' * 'data)
  | TableQuery of
      ((* the tables: *) (string * 'data expression') list *
       (* the query: *) Query.query *
        'data)
  | TableHandle of ((* the database: *) 'data expression' 
      * (* the table name: *) 'data expression'
      * (* the read / write (record) types of a table row: *) 
        (Types.datatype * Types.datatype)
      * 'data)
     
  | SortBy of ('data expression' * 'data expression' * 'data)
  | Call_cc of ('data expression' * 'data)
  | Wrong of 'data
  | HasType of ('data expression' * Types.datatype * 'data)
  | Alien of (string * string * Types.assumption * 'data)
  | Placeholder of (label * 'data)
      deriving (Eq, Typeable, Show, Pickle, Functor, Rewriter, Shelve)
      (* Q: Should syntax exprs be picklable or not? *)

let unit_expression data = Record_intro (StringMap.empty, None, data)

let is_define = 
  function
    | Define _
    | TypeDecl _
    | Alien _ -> true
    | _ -> false

let defined_names exprs = 
  concat_map (function Define(f, _, _, _) -> [f] | _ -> []) exprs

(* Whether a syntax node is a value for the purposes of generalization.
   This means, approximately "it doesn't contain any applications" *)
let rec is_value : 'a expression' -> bool = function
  | Boolean _
  | Integer _
  | Char _
  | String _
  | Float _
  | Variable _
  | Xml_node _ (* ? *)
  | Nil _
  | Abstr _ -> true
  | HasType (e, _, _)
  | Project (e, _, _)
  | Erase (e, _,_)
  | Variant_injection (_, e, _)
  | Variant_selection_empty (e, _)
  | Database (e, _)
  | List_of (e, _) -> is_value e
  | TableHandle (a, b, _, _)
  | Comparison (a,_,b,_)
  | Concat (a, b, _)
  | For (a, _, b, _)
  | Record_selection (_, _, _, a, b, _)
  | Let (_, a, b,_)  -> is_value a && is_value b
  | Variant_selection (a, _, _, b, _, c, _)
  | Condition (a,b,c,_) -> is_value a && is_value b && is_value c
  | Record_intro (bs, e, _) ->
      StringMapUtils.for_all (is_value) bs && opt_app is_value true e
  | Rec (bs, e, _) -> List.for_all (is_value -<- (fun (_,x,_) -> x)) bs && is_value e
  | _ -> false

type typed_data = [`T of (position * Types.datatype * label option)] deriving (Eq, Typeable, Show, Pickle, Shelve)
type untyped_data = [`U of position] deriving (Eq, Typeable, Show, Pickle, Shelve)
type data = [untyped_data | typed_data] deriving (Typeable, Show, Pickle)

type expression = typed_data  expression'
and untyped_expression = untyped_data expression'
and stripped_expression = unit expression'
  deriving (Eq, Typeable, Show, Pickle, Shelve)

let data_position = function
  | `T (pos, _, _)
  | `U pos -> pos

let is_symbolic_ident name = 
  (Str.string_match (Str.regexp "^[!$%&*+/<=>?@\\^-.|_]+$") name 0)

let is_alphanumeric_ident name = 
  (Str.string_match (Str.regexp "^[a-zA-Z_][a-zA-Z_0-9]*$") name 0)

let rec show t : 'a expression' -> string = function 
  | HasType(expr, datatype, data) -> show t expr ^ " : " ^ Types.string_of_datatype datatype ^ t data
  | Define (variable, value, location, data) -> 
      (if is_symbolic_ident variable then "(" ^ variable ^ ")" else variable) 
      ^ "=" ^ show t value
      ^ "[" ^ Show_location.show location ^ "]; " ^ t data
  | TypeDecl (typename, quantifiers, datatype, data) ->
      "typename "^typename^"(TODO:update pretty-printer to display quantifiers) = "^ Types.string_of_datatype datatype ^ t data
  | Boolean (value, data) -> string_of_bool value ^ t data
  | Integer (value, data) -> string_of_num value ^ t data
  | Char (c, data) -> "'"^ Char.escaped c ^"'" ^ t data
  | String (s, data) -> "\"" ^ s ^ "\"" ^ t data
  | Float (value, data)   -> string_of_float value ^ t data
  | Variable (name, data) when is_symbolic_ident name -> "(" ^ name ^ ")" ^ t data
  | Variable (name, data) -> name ^ t data
  | Apply (f, p, data)    -> show t f ^ "(" ^ show t p ^ ")" ^ t data
  | Condition (cond, if_true, if_false, data) ->
      "if (" ^ show t cond ^ ") " ^ show t if_true ^ " else " ^ show t if_false ^ t data
  | Comparison (left_value, oper, right_value, data) ->
      show t left_value ^ " " ^ string_of_comparison oper ^ " " ^ show t right_value ^ t data
  | Abstr (variable, body, data) ->
      "fun (" ^ variable ^ ") { " ^ show t body ^ " }" ^ t data
  | Let (variable, value, body, data) ->
      "{ var " ^ variable ^ "=" ^ show t value ^ "; " ^ show t body ^ "}" ^ t data
  | Rec (variables, body, data) ->
      "{" ^ (String.concat " ; " (map (function (label, expr, _) -> " " ^ label ^ "=" ^ show t expr) variables))
      ^ "; " ^ show t body ^ "}" ^ t data
  | Call_cc (Abstr(var, body, _), data) -> 
      "escape " ^ var ^ " in " ^ show t body ^ t data
  | Call_cc (f, data) -> "callCC " ^ show t f ^ t data
  | Xml_node (tag, attrs, elems, data) ->  
      let attrs = 
        let attrs = String.concat " " (map (fun (k, v) -> k ^ "=\"" ^ show t v ^ "\"") attrs) in
          match attrs with 
            | "" -> ""
            | _ -> " " ^ attrs in
        (match elems with 
           | []    -> "<" ^ tag ^ attrs ^ "/>" ^ t data
           | elems -> "<" ^ tag ^ attrs ^ ">" ^ String.concat "" (map (show t) elems) ^ "</" ^ tag ^ ">" ^ t data)
  | Record_intro (bs, r, data) ->
      "(" ^
        String.concat ","
        (StringMapUtils.zip_with (fun label e -> label ^ "=" ^ (show t e)) bs) ^
        (opt_app (fun e -> " | " ^ show t e) "" r) ^
        ")" ^ t data
  | Record_selection (label, label_variable, variable, value, body, data) ->
      "{(" ^ label ^ "=" ^ label_variable ^ "|" ^ variable ^ ") = " 
      ^ show t value ^ "; " ^ show t body ^ "}" ^ t data
  | Project (e, l, data) -> show t e ^ "." ^ l ^ t data
  | Erase (e, l, data) -> show t e ^ "\\" ^ l ^ t data
  | Variant_injection (label, value, data) ->
      label ^ "(" ^ show t value ^ ")" ^ t data
  | Variant_selection (value, case_label, case_variable, case_body, variable, body, data) ->
      "case " ^ show t value ^ " of " ^ case_label ^ "=" 
      ^ case_variable ^ " in " ^ (show t case_body) ^ " | " 
      ^ variable ^ " in " ^ show t body ^ t data
  | Variant_selection_empty (value, data) ->
      show t value ^ " is empty " ^ t data
  | Nil (data)              -> "[]" ^ t data
  | List_of (elem, data)       -> "[" ^ show t elem ^ "]" ^ t data
  | Concat (left, right, data) -> 
      "(" ^ show t left ^ t data ^ "++" ^ show t right ^ ")" 
  | For (expr, variable, value, data) ->
      "(for (" ^ variable ^ " <- " ^ show t value ^ ") " ^ show t expr ^ ")" ^ t data
  | Database (params, data) -> "database (" ^ show t params ^ ")" ^ t data
  | TableHandle (db, name, (readtype, writetype), data) ->
      "("^ show t name ^" from "^ show t db ^
      "["^Types.string_of_datatype readtype^";"^Types.string_of_datatype writetype^"])" ^ t data
  | TableQuery (ths, query, data) ->
      "("^ mapstrcat "," (fun (alias, th) -> show t th ^ "("^alias^")") ths ^
        "["^Sql.string_of_query query^"])" ^ t data
  | SortBy (expr, byExpr, data) ->
      "sort (" ^ show t expr ^ ") by (" ^ show t byExpr ^ ")" ^ t data
  | Wrong data -> "wrong" ^ t data
  | Placeholder (s, data) -> "PLACEHOLDER : " ^ Utility.base64encode s ^ t data
  | Alien (s1, s2, k, data) -> Printf.sprintf "alien %s %s : %s;" s1 s2 (Types.string_of_assumption k) ^ t data

let string_of_expression s = show (fun _ -> "") s

let as_string = string_of_expression

let labelled_string_of_expression s = 
  show (function
            `T (_,_,Some lbl) -> "(label:" ^ Utility.base64encode(lbl) ^ ")"
          | _ -> "(NO LABEL)") s

let strip_data : 'a expression' -> stripped_expression =
  fun e -> Functor_expression'.map (fun _ -> ()) e

let erase : expression -> untyped_expression = 
  Functor_expression'.map (fun (`T (pos, _, _)) -> `U pos)

let reduce_expression (visitor : ('a expression' -> 'b) -> 'a expression' -> 'b)
    (combine : (('a expression' * 'b list) -> 'c)) : 'a expression' -> 'c =
  (* The "default" action: do nothing, just process subnodes *)
  let rec visit_children expr = 
    combine (expr, match expr with
               | Boolean _
               | Integer _
               | Char _
               | String _
               | Float _
               | Nil _
               | Alien _
               | Placeholder _ 
               | Wrong _
               | TypeDecl _
               | Variable _ -> []

               | Variant_selection_empty (e, _)
               | Define (_, e, _, _)
               | Abstr (_, e, _)
               | Database (e, _)
               | Variant_injection (_, e, _)
               | Project (e, _, _)
               | Erase (e, _, _)
               | List_of (e, _)
               | Call_cc(e, _)
               | HasType (e, _, _) -> [visitor visit_children e]

               | TableQuery (es, _, _) -> (map (fun (_,e) -> visitor visit_children e) es)

               | TableHandle (e1, e2, _, _)
               | Apply (e1, e2, _)
               | Comparison (e1, _, e2, _)
               | Let (_, e1, e2, _)
               | Concat (e1, e2, _)
               | Record_selection (_, _, _, e1, e2, _)
               | For (e1, _, e2, _)
               | SortBy (e1, e2, _) ->
                   [visitor visit_children e1; visitor visit_children e2]
                   
               | Condition (e1, e2, e3, _)
               | Variant_selection (e1, _, _, e2, _, e3, _) ->
                   [visitor visit_children e1; visitor visit_children e2; visitor visit_children e3]
               | Record_intro (bs, r, _) ->
                   (StringMapUtils.zip_with (fun _ e -> visitor visit_children e) bs) @
                     (opt_app (fun e -> [visitor visit_children e]) [] r)
               | Rec (b, e, _) -> map (fun (_, e, _) -> visitor visit_children e) b @ [visitor visit_children e]
               | Xml_node (_, es1, es2, _)          -> map (fun (_,v) -> visitor visit_children v) es1 @ map (visitor visit_children) es2)
  in
    visitor visit_children

(* This is a candidate for `deriving', I think, perhaps in conjunction with a fold *)
let set_subnodes (exp : 'a expression') (exps : 'a expression' list) : 'a expression' =
  match exp, exps with
      (* 0 subnodes *)
    | TypeDecl _, []
    | Boolean _, []
    | Integer _, []
    | Char _, []
    | String _, []
    | Float _, []
    | Variable _, []
    | Nil _, [] 
    | Placeholder _, []
    | Wrong _, []
    | Alien _, [] -> exp
        
    (* 1 subnodes *)
    | Define (a, _, l, d)            , [e] -> Define (a, e, l, d)
    | Abstr (s, _, d)                , [e] -> Abstr (s, e, d)
    | Project (_, s, d)              , [e] -> Project (e, s, d)
    | Erase (_, s, d)                , [e] -> Erase (e, s, d)
    | Variant_injection (s, _, d)    , [e] -> Variant_injection (s, e, d)
    | Variant_selection_empty (_, d) , [e] -> Variant_selection_empty (e, d)
    | List_of (_, d)                 , [e] -> List_of (e, d)
    | Database (_, d)                , [e] -> Database (e, d)
    | Call_cc (_, d)                 , [e] -> Call_cc (e, d)
    | HasType (_, t, d)              , [e] -> HasType (e, t, d)

    (* 2 subnodes *)
    | Apply (_, _, d)                        , [e1;e2] -> Apply (e1, e2, d)
    | Comparison (_, c, _, d)                , [e1;e2] -> Comparison (e1, c, e2, d)
    | Let (s, _, _, d)                       , [e1;e2] -> Let (s, e1, e2, d)
    | Record_selection (s1, s2, s3, _, _, d) , [e1;e2] -> Record_selection (s1, s2, s3, e1, e2, d)
    | Concat (_, _, d)                       , [e1;e2] -> Concat (e1, e2, d)
    | For (_, s, _, d)                       , [e1;e2] -> For (e1, s, e2, d)
    | TableHandle (_, _, t, d)               , [e1;e2] -> TableHandle (e1, e2, t, d)
    | SortBy (_, _, d)                       , [e1;e2] -> SortBy (e1, e2, d)

    (* 3 subnodes *)
    | Condition (_, _, _, d), [e1;e2;e3] -> Condition (e1, e2, e3, d)
    | Variant_selection (_, s1, s2, _, s3, _, d), [e1;e2;e3] -> Variant_selection (e1, s1, s2, e2, s3, e3, d)

    (* n subnodes *)
    | Rec (bindings, _, d), (_::_ as nodes) ->
        let others, body = unsnoc nodes in 
          Rec (List.map2 (fun (a,_,c) b -> (a,b,c)) bindings others, body, d)
    | Record_intro (fields, None, d), nodes -> 
        let addnode k _ ((node::nodes), map) = nodes, StringMap.add k node map in
          Record_intro (snd (StringMap.fold addnode fields (nodes, StringMap.empty)), None, d)
    | Record_intro (fields, Some _, d), (_::_ as nodes) -> 
        let addnode k _ ((node::nodes), map) = nodes, StringMap.add k node map in
        let others, expr = unsnoc nodes in
          Record_intro (snd (StringMap.fold addnode fields (others, StringMap.empty)), Some expr, d)
    | Xml_node (tag, attrs, _, d), nodes -> (* (string, ((string, EXP) list), (EXP list), 'data)*)
        let nattrs = length attrs in
        let attrnodes, childnodes = take nattrs nodes, drop nattrs nodes in
          Xml_node (tag, 
                    List.map2 (fun (k,_) v -> (k,v)) attrs attrnodes,
                    childnodes,
                    d)
    | TableQuery (es, q, d), nodes ->
        TableQuery (List.map2 (fun (k,_) v -> (k,v)) es nodes, q, d)
    | e -> raise (Invalid_argument "set_subnodes")
        
let rec stringlit_value = function
  | HasType (e, _, _) -> stringlit_value e
  | String (name, _) -> name
  | _ -> assert false

(* Walk the XML tree, looking for <input l:name> bindings that are
   inside the top <form> element, with no intervening <form>s.
*)
let lname_bound_vars : 'a expression' -> string list = 
  let rec lnames = function
    | Xml_node (("input"|"textarea"|"select"), attrs, contents, _) ->
        (try 
          let lname_attr = assoc "l:name" attrs in 
            (try
               [stringlit_value(lname_attr)]
             with
               | Match_failure _ ->failwith("l:name attribute was not a string: "
                                           ^ string_of_expression lname_attr))
        with Not_found -> concat (map lnames contents))
    | Xml_node ("form", _, _, _) -> (* new scope *) []
    | Xml_node (_, _, contents, _) -> concat (map lnames contents)
    | Concat (l, r, _) -> lnames l @ lnames r
    | _ -> [] 
  in function
    | Xml_node ("form", _, contents, _)  ->
        concat (map lnames contents)
    | Xml_node (_, _, _, _)  -> []
        

let freevars (expression : 'a expression') : string list = 
  let combine = unduplicate (=) -<-List.concat in
  let rec aux default = function
    | Variable (name, _) -> [name]
    | For (body, var, generator, _) -> aux default generator @ remove var (aux default body)
    | Let (var, value, body, _) -> aux default value @ (remove var (aux default body))
    | Abstr (var, body, _) -> remove var (aux default body)
    | Record_selection (_, labvar, var, value, body, _) ->
        aux default value @ (remove_all [var;labvar] (aux default body))
    | Variant_selection (value, _, cvar, cbody, var, body, _) ->
        aux default value @ (remove cvar (aux default cbody)) @ (remove var (aux default body))
    | Rec (bindings, body, _) ->
        let vars, vals = List.split (map (fun (n,v,_) -> (n,v)) bindings) in
          remove_all vars (concat_map (aux default) (body::vals))
    | TableQuery (_, query, _) -> Query.freevars query
    | Xml_node (_, attrs, children, _) as x -> 
        remove_all (lname_bound_vars x) 
          (concat_map (snd ->- aux default) attrs @ concat_map (aux default) children)
    | other -> default other
  in 
    unduplicate (=) (reduce_expression aux (combine -<- snd) expression)
          
let rec list_expr data = function
    [] -> Nil(data)
  | expr::etc -> Concat(List_of(expr, data), list_expr data etc, data)

let expression_data : ('a expression' -> 'a) = function 
        | Define (_, _, _, data) -> data
        | TypeDecl (_, _, _, data) -> data
        | HasType (_, _, data) -> data
        | Boolean (_, data) -> data
        | Integer (_, data) -> data
        | Float (_, data) -> data
        | Char (_, data) -> data
        | String (_, data) -> data
        | Variable (_, data) -> data
        | Apply (_, _, data) -> data
        | Condition (_, _, _, data) -> data
        | Comparison (_, _, _, data) -> data
        | Abstr (_, _, data) -> data
        | Let (_, _, _, data) -> data
        | Rec (_, _, data) -> data
        | Xml_node (_, _, _, data) -> data
        | Record_intro (_, _, data) -> data
        | Record_selection (_, _, _, _, _, data) -> data
        | Project (_,_,data) -> data
        | Erase (_,_,data) -> data
        | Variant_injection (_, _, data) -> data
        | Variant_selection (_, _, _, _, _, _, data) -> data
        | Variant_selection_empty (_, data) -> data
        | Nil (data) -> data
        | List_of (_, data) -> data
        | Concat (_, _, data) -> data
        | For (_, _, _, data) -> data
        | Database (_, data) -> data
        | TableQuery (_, _, data) -> data
        | TableHandle (_, _, _, data) -> data
        | SortBy (_, _, data) -> data
        | Call_cc (_, data) -> data
        | Wrong data -> data
        | Alien (_,_,_,data) -> data
        | Placeholder (_,data) -> data

(** [set_data] sets the data member of an expression to a given value;
 *)
let rec set_data : ('b -> 'a expression' -> 'b expression') =
  fun data -> function
  | Define (a, b, c, _) -> 
      Define (a, b, c, data)
  | TypeDecl (a, b, c, _) -> TypeDecl (a, b, c, data)
  | HasType (a, b,_) ->  HasType (a, b,data) 
  | Boolean (a, _) -> Boolean (a, data)
  | Integer (a, _) -> Integer (a, data)
  | Float (a, _) ->  Float (a, data)
  | Char (a, _) -> Char (a, data)
  | String (a, _) -> String (a, data)
  | Variable (a, _) -> Variable (a, data)
  | Apply (a, b,_) -> Apply (a, b,data)
  | Condition (a, b, c, _) -> Condition (a, b, c, data)
  | Comparison (a, b, c, _) -> Comparison (a, b, c, data)
  | Abstr (a, b,_) -> Abstr (a, b,data)
  | Let (a, b, c, _) -> Let (a, b, c, data) 
  | Rec (a, b,_) -> Rec (a, b,data)
  | Xml_node (a, b, c, data) ->  Xml_node (a, b, c, data)
  | Record_intro (a, b,_) -> Record_intro (a, b,data)
  | Record_selection (a, b, c, d, e, _) -> 
      Record_selection (a, b, c, d, e,data)
  | Variant_injection (a, b,_) ->  Variant_injection (a, b,data)
  | Variant_selection (a, b, c, d, e, f, _) ->
      Variant_selection (a, b, c, d, e, f, data)
  | Variant_selection_empty (a, _) -> Variant_selection_empty (a, data)
  | Nil (_) -> Nil (data)
  | List_of (a, _) -> List_of (a, data)
  | Concat (a, b,_) -> Concat (a, b,data)
  | For (a, b, c, _) -> For (a, b, c, data)
  | Database (a, _) ->  Database (a, data)
  | TableQuery (a, b,_) ->  TableQuery (a, b,data)
  | TableHandle (a, b, c, _) -> TableHandle (a, b, c, data)
  | SortBy (a, b,_) -> SortBy (a, b,data)
  | Call_cc (a, _) -> Call_cc (a, data)
  | Wrong _ -> Wrong data
  | Alien (a, b, c,_) ->  Alien (a, b, c,data)
  | Placeholder (a,_) -> Placeholder (a,data) 
      

let node_datatype : (expression -> Types.datatype) = (fun (`T(_, datatype, _)) -> datatype) -<- expression_data

let position e = data_position (expression_data e)

let no_expr_data = `T(dummy_position, `Not_typed, None)

module RewriteSyntax = Rewrite_expression'(struct type a = typed_data end)
module RewriteUntypedExpression = Rewrite_expression'(struct type a = untyped_data end)
  
let rec map_free_occ u f expr =
  let recurse = map_free_occ u f in
  let rec rewrite = function
    | Variable(x, _) as node when x = u -> Some (f node)
    | Abstr(x, body, d) when x <> u -> Some (Abstr(x, recurse body, d))
    | Abstr _ -> None
    | Let(letvar, letval, body, d) ->
        Some(Let(letvar, recurse letval, 
                 (if u <> letvar then recurse body else body), d))
    | Rec(defs, body, d) when (not (mem_assoc3 u defs)) ->
        Some(Rec(map (fun (n, defn, t) -> (n, recurse defn, t)) defs, 
                 recurse body, d))
    | Record_selection(label, label_var, etc_var, src, body, d) ->
        Some(Record_selection(label, label_var, etc_var, recurse src, 
                              (if (u <> label_var && u <> etc_var) then
                                 recurse body else body), d))
    | Variant_selection(value, case_label, case_variable, case_body, 
                        etc_var, etc_body, d) ->
        Some(Variant_selection(recurse value, case_label, case_variable, 
                          (if u <> case_variable then
                             recurse case_body
                           else case_body),
                          etc_var,
                          (if u <> etc_var then 
                             recurse etc_body
                           else etc_body), 
                          d))
    | For(body, loop_var, src, d) ->
        Some(For((if (u <> loop_var) then recurse body else body),
                 loop_var, recurse src, d))
    | expr -> RewriteUntypedExpression.process_children rewrite expr
  in fromOption expr (rewrite expr)

let subst_free u r expr =
  map_free_occ u (fun _ -> r) expr

(**
   [rename_free e u v]
   Substitutes the variable [v] for free occurrences of [u] in the expression [e].
   Note: this is *not* presently capture-avoiding (but perhaps it should be).
*)

let rename_free u v e =
  map_free_occ u (fun (Variable(x, d)) -> Variable(v, d)) e


let subst_fast name replacement expr =
  let replacer name replacement : RewriteSyntax.rewriter = function
    | Variable (n, _) when n = name -> Some replacement
    | _ -> None
  in
    fromOption expr (RewriteSyntax.bottomup (replacer name replacement) expr)

let rename_fast name replacement expr = 
  let replacer name replacement : RewriteSyntax.rewriter = function
    | Variable (n, d) when n = name -> Some (Variable(replacement, d))
    | TableQuery(th, q, data) -> 
        let q = Query.query_replace_var name (Query.Variable replacement) q in
          Some(TableQuery(th, q, data)) 
    | _ -> None
  in
    fromOption expr (RewriteSyntax.bottomup (replacer name replacement) expr)

(** {0 Sanity Checks} *)

let is_closed expr = freevars expr == []

let is_closed_wrt expr freebies = freevars expr <|subset|> freebies

(** {0 Labelizing} *)

let set_label expr lbl = 
  let (`T(pos, t, _)) = expression_data expr in
    set_data (`T(pos, t, lbl)) expr

let has_label expr =
  match expression_data expr with
      (_,_,None) -> false
    | (_,_,Some _) -> true

let label_for_expr expr =
  (Digest.string -<- string_of_expression) expr

let labelize expr =
  (function None -> expr
     | Some x -> x)
    (RewriteSyntax.topdown 
       (fun expr -> 
          Some(set_label expr (Some(label_for_expr expr))))
       expr)

(** {0 Skeleton} *)

(** [skeleton] has a case for each of the [Syntax] constructors, and
    gives an approrpiate name to each component. Use this to get 
    started on a function that takes Syntax trees by case. *)
let skeleton = function
    (* Zero sub-expressions *)
  | Nil d -> Nil d
  | Wrong d -> Wrong d
  | Boolean(value, d) -> Boolean(value, d)
  | Integer(value, d) -> Integer(value, d)
  | Char(value, d) -> Char(value, d)
  | String(value, d) -> String(value, d)
  | Float(value, d) -> Float(value, d)
  | Variable(x, d) -> Variable(x, d)
  | Apply(f, a, d) -> Apply(f, a, d)
  | TypeDecl(typename, quantifiers, datatype, d) ->
      TypeDecl(typename, quantifiers, datatype, d)
  | Placeholder(label, d) -> Placeholder(label, d)
  | Alien(language, name, assumption, d) -> Alien(language, name, assumption, d)
  | TypeDecl(typename, quantifiers, datatype, d) -> TypeDecl(typename, quantifiers, datatype, d)

  (* One sub-expression *)
  | Define(name, expr, loc_annotation, d) ->
      Define(name, expr, loc_annotation, d)
  | Abstr(var, body, d) -> Abstr(var, body, d)
  | Variant_injection(label, value_expr, d) -> 
      Variant_injection(label, value_expr, d)
  | Variant_selection_empty(src_expr, d) -> 
      Variant_selection_empty(src_expr, d)
  | List_of(single_member, d) -> List_of(single_member, d)
  | Database(db_args_expr, d) -> Database(db_args_expr, d)
  | HasType(expr, datatype, d) -> HasType(expr, datatype, d)
      
  (* Two sub-expressions *)
  | Comparison(lhs, op, rhs, d) -> Comparison(lhs, op, rhs, d)
  | Let(letvar, letsrc, letbody, d) -> Let(letvar, letsrc, letbody, d)
  | Record_selection(label, labelvar, etcvar, src, body, d) ->
      Record_selection(label, labelvar, etcvar, src, body, d)
  | Project (expr, label, d) -> Project (expr, label, d)
  | Concat(lhs, rhs, d) -> Concat(lhs, rhs, d)
  | For(body, loop_var, src, d) -> For(body, loop_var, src, d)
  | SortBy(list_target, sort_func, d) -> SortBy(list_target, sort_func, d)
  | TableHandle(db_expr, tablename_expr, t, d) -> 
      TableHandle(db_expr, tablename_expr, t, d)
  | Call_cc(body, d) -> Call_cc(body, d)

  (* Three sub-expressions *)
  | Condition(condn, ifcase, elsecase, d) -> 
      Condition(condn, ifcase, elsecase, d)
  | Variant_selection(src_expr, case_label, case_variable, case_body, 
                      etc_var, etc_body, d) -> 
      Variant_selection(src_expr, case_label, case_variable, case_body, 
                      etc_var, etc_body, d)

  (* n-ary expressions *)
  | Record_intro(bs, r, d) -> Record_intro(bs, r, d)
  | Rec(defs, body, d) -> Rec(defs, body, d)
  | Xml_node(tagname, attrs, contents, d) -> 
      Xml_node(tagname, attrs, contents, d)
  | TableQuery(thandle_alist, query, d) -> TableQuery(thandle_alist, query, d)
      (* note: besides the alist, [query] can also contain
         expressions, in the [query.ml] sublanguage *)

