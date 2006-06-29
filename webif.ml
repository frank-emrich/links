open Utility
open Result


type query_params = (string * result) list

type web_request = ContInvoke of continuation * query_params
                   | ExprEval of Syntax.expression * environment
                   | ClientReturn of continuation * result
                   | RemoteCall of result * result
                   | CallMain

(*
  [REMARKS]
   - Currently print_http_response outputs the headers and body in
   one go.
   - At some point in the future we may want to consider implementing
   some form of incremental output.
   - Flushing the output stream prematurely (e.g. after outputting
   the headers and newline) appears to break client calls.
*)

(* output the headers and content to stdout *)
let print_http_response headers body =
  List.map (fun (name, value) -> print_endline(name ^ ": " ^ value)) headers;
  print_endline "";
  print_string body

(* Does at least one of the functions have to run on the client? *)
let is_client_program defs =
  let is_client_def = function
    | Syntax.Define (_, _, `Client, _) -> true
    | _ -> false 
  and toplevels = (concat_map 
                     (function
                        | Syntax.Define (n, _, _, _) -> [n]
                        | _ -> [])) defs
  and is_client_prim p = 
    (* Sytnax.freevars is currently broken: it doesn't take l:name
       bindings into account.  It's tricky to fix, because the Syntax
       module doesn't know about l:name.  The problem that arises here
       is that anything bound by l:name ends up looking like a
       primitive (because analysis indicates that it's free in the
       program).  When l:name goes away this problem will, too.  
       Let's just work around it for now. *)
    try 
      (Library.primitive_location ->- (=) `Client) p
    with Not_found ->  false
  in
  let freevars = Utility.concat_map Syntax.freevars defs in
  let prims = List.filter (not -<- flip List.mem toplevels) freevars
  in 
    List.exists is_client_def defs || List.exists is_client_prim prims
          

(* Read in and optimise the program *)
let read_and_optimise_program filename : (Syntax.expression list) = 
  Settings.set_value Performance.measuring false; (* temp *)
  (Performance.measure "optimise" Optimiser.optimise_program)
    ((fun (env, exprs) -> env, List.map Syntax.labelize exprs)
       ((Performance.measure "type" (Inference.type_program Library.type_env))
          ((Performance.measure "parse" Parse.parse_file) filename)))
              
let encode_continuation (cont : Result.continuation) : string =
  Utility.base64encode (Marshal.to_string cont [Marshal.Closures])

let serialize_call_to_client (continuation, name, arg) =
  Json.jsonize_result
    (`Record [
       "__continuation", Result.string_as_charlist (encode_continuation continuation);
       "__name", Result.string_as_charlist name;
       "__arg", arg
     ])

let parse_json = Jsonparse.parse_json Jsonlex.jsonlex -<- Lexing.from_string

let untuple_single = function
  | `Record ["1",arg] -> arg
  | r -> r

let stubify_client_funcs env = 
  let is_server_fun = function
    | Syntax.Define (_, _, (`Server|`Unknown), _) -> true
    | Syntax.Define (_, _, (`Client|`Native), _) -> false
    | Syntax.Alien ("javascript", _, _, _) -> false
    | e  -> failwith ("Unexpected non-definition in environment : " 
		      ^ Syntax.string_of_expression e)
  in 
  let server_env, client_env = List.partition is_server_fun env in
    List.iter (function
                 | Syntax.Define (name, _, _, _)
                 | Syntax.Alien (_, name, _, _) -> 
		      let f (_, cont, arg) =
			let call = serialize_call_to_client (cont, name, arg) in
			  (print_endline ("Content-type: text/plain\n\n" ^ 
					    Utility.base64encode call);
			   exit 0)
		      in 
                        Library.value_env := (name,`PFun f):: !Library.value_env)
      client_env;
    match server_env with 
        [] -> []
      | server_env ->
          fst (Interpreter.run_program [] server_env)

(* let handle_client_call unevaled_env f args =  *)
(*   let env = stubify_client_funcs unevaled_env in *)
(*   let f, args = Utility.base64decode f, Utility.base64decode args in *)
(*   let continuation = [Result.FuncApply (List.assoc f env, [])] in *)
(*   let result = (Interpreter.apply_cont_safe env continuation *)
(* 		  (untuple_single (parse_json args))) *)
(*   in *)
(*     print_http_response [("Content-type", "text/plain")] *)
(*       (Utility.base64encode (Json.jsonize_result result)); *)
(*     exit 0 *)

let get_remote_call_args env cgi_args = 
  let fname = Utility.base64decode (List.assoc "__name" cgi_args) in
  let args = Utility.base64decode (List.assoc "__args" cgi_args) in
  let args = untuple_single (parse_json args) in
    RemoteCall(List.assoc fname env, args)

let decode_continuation (cont : string) : Result.continuation =
  let fixup_cont = 
  (* At some point, '+' gets replaced with ' ' in our base64-encoded
     string.  Here we put it back as it was. *)
    Str.global_replace (Str.regexp " ") "+" 
  in Marshal.from_string (Utility.base64decode (fixup_cont cont)) 0

let is_special_param (k, _) =
  List.mem k ["_cont"; "_k"]

let string_dict_to_charlist_dict =
  dict_map Result.string_as_charlist

let lookup_either a b env = 
  try List.assoc a env
  with Not_found -> List.assoc b env

(* Extract continuation from the parameters passed in over CGI.*)
let contin_invoke_req program params =
  let pickled_continuation = List.assoc "_cont" params in
  let params = List.filter (not -<- is_special_param) params in
  let params = string_dict_to_charlist_dict params in
    ContInvoke(unmarshal_continuation program pickled_continuation, params)

(* Extract expression/environment pair from the parameters passed in over CGI.*)
let expr_eval_req program prim_lookup params =
  let expression, environment = unmarshal_exprenv program (List.assoc "_k" params) in
(*  let expression = resolve_placeholders_expr program expression in*)
  let params = List.filter (not -<- is_special_param) params in
  let params = string_dict_to_charlist_dict params in
    ExprEval(expression, params @ environment)

let is_remote_call params =
  List.mem_assoc "__name" params && List.mem_assoc "__args" params

let is_func_appln params =
  List.mem_assoc "__name" params && List.mem_assoc "__args" params

let is_client_call_return params = 
  List.mem_assoc "__continuation" params && List.mem_assoc "__result" params

let is_contin_invocation params = 
  List.mem_assoc "_cont" params

let is_expr_request = List.exists is_special_param
        
let client_return_req env cgi_args = 
  let continuation = decode_continuation (List.assoc "__continuation" cgi_args) in
  let parse_json_b64 = parse_json -<- Utility.base64decode in
  let arg = parse_json_b64 (List.assoc "__result" cgi_args) in
    ClientReturn(continuation, untuple_single arg)

let perform_request program globals main req =
  match req with
    | ContInvoke (cont, params) ->
	let f = print_http_response [("Content-type", "text/html")]
	in
          f (Result.string_of_result 
               (Interpreter.apply_cont_safe globals cont (`Record params)))
    | ExprEval(expr, env) ->
        let f = print_http_response [("Content-type", "text/html")]
	in
          f (Result.string_of_result 
             (snd (Interpreter.run_program (globals @ env) [expr])))
    | ClientReturn(cont, value) ->
	let f = print_http_response [("Content-type", "text/plain")]
	in
          f (Utility.base64encode 
             (Json.jsonize_result 
                (Interpreter.apply_cont_safe globals cont value)))
    | RemoteCall(func, arg) ->
        let cont = [Result.FuncApply (func, [])] in
        let f = print_http_response [("Content-type", "text/plain")] in
	  f (Utility.base64encode
               (Json.jsonize_result 
                  (Interpreter.apply_cont_safe globals cont arg)))
    | CallMain -> 
        print_http_response [("Content-type", "text/html")] 
          (if is_client_program program then
               Js.generate_program program main
           else Result.string_of_result (snd (Interpreter.run_program globals [main])))

let error_page_stylesheet = 
  "<style>pre {border : 1px solid #c66; padding: 4px; background-color: #fee}</style>"

let error_page body = 
  "<html>\n  <head>\n    <title>Links error</title>" ^ error_page_stylesheet ^ 
    "\n  </head>\n  <body>" ^ 
    body ^ 
    "\n  </body></html>"

let serve_requests filename = 
  try 
    Settings.set_value Performance.measuring true;
    Pervasives.flush(Pervasives.stderr);
    let program = read_and_optimise_program filename in
    let global_env, main = List.partition Syntax.is_define program in
    if (List.length main < 1) then raise Errors.NoMainExpr
    else if (List.length main > 1) then raise Errors.ManyMainExprs
    else
    let [main] = main in
    let global_env = stubify_client_funcs global_env in
    let cgi_args = Cgi.parse_args () in
    let request = 
      if is_remote_call cgi_args then 
        get_remote_call_args global_env cgi_args
      else if is_client_call_return cgi_args then
        client_return_req global_env cgi_args
      else if (is_contin_invocation cgi_args) then
        contin_invoke_req program cgi_args 
      else if (is_expr_request cgi_args) then
        expr_eval_req program (flip List.assoc global_env) cgi_args           
      else
        CallMain
    in
      perform_request program global_env main request
  with
      exc -> print_http_response [("Content-type", "text/html; charset=utf-8")]
        (error_page (Errors.format_exception_html exc))
          
let serve_requests filename =
  Errors.display_errors_fatal stderr
    serve_requests filename
