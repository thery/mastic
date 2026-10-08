(* elpi: embedded lambda prolog interpreter                                  *)
(* license: GNU Lesser General Public License Version 2.1 or later           *)
(* ------------------------------------------------------------------------- *)

open Elpi_util
open Elpi_lexer_config

exception ParseError = Parser_config.ParseError

module type Parser = sig
  val program : file:string -> Ast.Program.t
  val goal : loc:Util.Loc.t -> text:string -> Ast.Goal.t
  
  val goal_from : loc:Util.Loc.t -> Lexing.lexbuf -> Ast.Goal.t
  val program_from : loc:Util.Loc.t -> digest:Digest.t -> Lexing.lexbuf -> Ast.Program.t
end

module type Parser_w_Internals = sig
  include Parser

  module Internal : sig
    val infix_SYMB : (Lexing.lexbuf -> Tokens.token) -> Lexing.lexbuf -> Ast.Func.t
    val prefix_SYMB : (Lexing.lexbuf -> Tokens.token) -> Lexing.lexbuf -> Ast.Func.t
    val postfix_SYMB : (Lexing.lexbuf -> Tokens.token) -> Lexing.lexbuf -> Ast.Func.t

    (* error-resilient parsing, with Mastic: never fails, the errors are
       returned with the tokens inserted by the recovery *)
    val program_resilient : Lexing.lexbuf ->
      Mastic.ErrorResilientParser.error list * Mastic.ErrorResilientParser.completion list * Ast.Program.decl list
  end
end

module type Config = sig
  val versions : (int * int * int) Util.StrMap.t
  val resolver : ?cwd:string -> unit:string -> unit -> string

end

module Make(C : Config) = struct
  
let parse_ref : (?cwd:string -> string -> Ast.Program.t) ref =
  ref (fun ?cwd:_ _ -> assert false)
  

module ParseFile = struct
  let parse_file ?cwd file = !parse_ref ?cwd file
  let client_payload : Obj.t option ref = ref None
  let set_current_clent_loc_pyload x = client_payload := Some x
  let get_current_client_loc_payload () = !client_payload

end

module Grammar = Grammar.Make(ParseFile)
  
let message_of_state s = try Error_messages.message s with Not_found -> "syntax error"

let raise_parse_error lexbuf stateid =
  let message = message_of_state stateid in
  let loc = lexbuf.Lexing.lex_curr_p in
  let loc = {
    Util.Loc.client_payload = None;
    source_name = loc.Lexing.pos_fname;
    line = loc.Lexing.pos_lnum;
    line_starts_at = loc.Lexing.pos_bol;
    source_start = loc.Lexing.pos_cnum;
    source_stop = loc.Lexing.pos_cnum;
  } in
  raise (Parser_config.ParseError(loc,message))

let parse grammar lexbuf =
  let buffer, lexer = MenhirLib.ErrorReports.wrap Lexer.(token C.versions) in
  try
    Grammar.MenhirInterpreter.loop_handle
     (fun x -> x)
     (function (HandlingError e) -> raise_parse_error lexbuf Grammar.MenhirInterpreter.(current_state_number e) | _ -> assert false)
     (Grammar.MenhirInterpreter.lexer_lexbuf_to_supplier lexer lexbuf)
     (grammar lexbuf.lex_curr_p)
    (* grammar lexer lexbuf *)
  with
  | Ast.Term.NotInProlog(loc,message) ->
      raise (Parser_config.ParseError(loc,message^"\n"))
  | Lexer.Error(loc,message) ->
    let loc = {
      Util.Loc.client_payload = None;
      source_name = loc.Lexing.pos_fname;
      line = loc.Lexing.pos_lnum;
      line_starts_at = loc.Lexing.pos_bol;
      source_start = loc.Lexing.pos_cnum;
      source_stop = loc.Lexing.pos_cnum;
    } in
    raise (Parser_config.ParseError(loc,message))
  (* | Grammar.Error stateid -> raise_parse_error lexbuf stateid *)

(* Error-resilient parsing, with Mastic ---------------------------------- *)

module ProgramParser = struct
  type ast = Ast.Program.decl list
  type 'a checkpoint = 'a Grammar.MenhirInterpreter.checkpoint
  let main = Grammar.Incremental.program
  type token = Tokens.token
  let token = Lexer.token C.versions
end

module Recovery = struct
  type token = Tokens.token
  let show_token _ = ""
  type 'a symbol = 'a Grammar.MenhirInterpreter.symbol
  type xsymbol = Grammar.MenhirInterpreter.xsymbol
  type 'a terminal = 'a Grammar.MenhirInterpreter.terminal
  type 'a env = 'a Grammar.MenhirInterpreter.env
  type production = Grammar.MenhirInterpreter.production

  let pp_symbol : type a. a option -> Format.formatter -> a symbol -> unit =
    fun x fmt s ->
    let open Grammar.MenhirInterpreter in
    match x, s with
    | Some x, N N_decl -> Ast.Program.pp_decl fmt x
    | _ -> Format.fprintf fmt "_"

  (* DECL_ERROR_TOKEN is an error that only a declaration accepts: Mastic
     merges the stack into it up to the declaration, which becomes an error.
     It is marked by a piece Lex "\000", that survives the merges *)
  let decl_marker = "\000"
  let has_decl_marker e =
    List.exists (fun x -> Mastic.Error.unloc x = Mastic.Error.Lex decl_marker) e
  let match_error_token = function Tokens.ERROR_TOKEN x | Tokens.DECL_ERROR_TOKEN x -> Some x | _ -> None
  let build_error_token t = if has_decl_marker t then Tokens.DECL_ERROR_TOKEN t else Tokens.ERROR_TOKEN t
  let is_eof_token = function Tokens.EOF -> true | _ -> false

  (* the tokens the recovery may insert: closing brackets, and the final dot *)
  let token_of_terminal : type a. a terminal -> (string * token) option = function
    | T_RPAREN -> Some (")", Tokens.RPAREN)
    | T_RBRACKET -> Some ("]", Tokens.RBRACKET)
    | T_RCURLY -> Some ("}", Tokens.RCURLY)
    | T_FULLSTOP -> Some (".", Tokens.FULLSTOP)
    | _ -> None

  (* a token at the beginning of a line, or a keyword that begins a
     declaration, is a good point to restart parsing *)
  let restart_point t (p : Lexing.position) =
    p.pos_cnum = p.pos_bol ||
    match t with
    | Tokens.PRED | Tokens.FUNC | Tokens.TYPE | Tokens.KIND | Tokens.NAMESPACE
    | Tokens.TYPEABBREV | Tokens.ACCUMULATE | Tokens.SHORTEN | Tokens.MACRO
    | Tokens.CONSTRAINT | Tokens.RULE -> true
    | _ -> false

  (* An item of the stack folded into an error keeps its content: terms,
     types, attributes and declarations become the error nodes of their
     type, the elements of lists are kept one by one, names and strings
     are kept as text *)
  let pos_of_loc { Util.Loc.source_name; line; line_starts_at; source_start; source_stop; _ } =
    let p n = { Lexing.pos_fname = source_name; pos_lnum = line; pos_bol = line_starts_at; pos_cnum = n } in
    p source_start, p source_stop
  let term (t : Ast.Term.t) = let b, e = pos_of_loc t.loc in Ast.Term.build_token (Mastic.Error.loc t b e)
  let ty (t : Ast.raw_attribute list Ast.TypeExpression.t) =
    let b, e = pos_of_loc t.tloc in Ast.TypeExpression.build_token (Mastic.Error.loc t b e)
  let text s b e = Mastic.Error.(mkLexError (loc s b e))
  let all f l b e = match List.map f l with [] -> text "" b e | x :: xs -> List.fold_left Mastic.Error.merge x xs

  let reduce_as_parse_error : type a. a -> a symbol -> Lexing.position -> Lexing.position -> token =
    let open Grammar.MenhirInterpreter in
    fun x s b e ->
    Tokens.ERROR_TOKEN (match s with
    | N N_decl -> Ast.Program.build_token (Mastic.Error.loc x b e)
    | N N_ignored -> Ast.Program.build_token (Mastic.Error.loc x b e)
    | N N_term ->
        Ast.Term.build_token (Mastic.Error.loc x b e)
    | N N_term_noconj ->
        Ast.Term.build_token (Mastic.Error.loc x b e)
    | N N_closed_term ->
        Ast.Term.build_token (Mastic.Error.loc x b e)
    | N N_head_term ->
        Ast.Term.build_token (Mastic.Error.loc x b e)
    | N N_open_term ->
        Ast.Term.build_token (Mastic.Error.loc x b e)
    | N N_open_term_noconj ->
        Ast.Term.build_token (Mastic.Error.loc x b e)
    | N N_binder_term ->
        Ast.Term.build_token (Mastic.Error.loc x b e)
    | N N_binder_term_noconj ->
        Ast.Term.build_token (Mastic.Error.loc x b e)
    | N N_goal ->
        Ast.Term.build_token (Mastic.Error.loc x b e)
    | N N_clause_hd_term ->
        Ast.Term.build_token (Mastic.Error.loc (snd x) b e)
    | N N_clause_hd_closed_term ->
        Ast.Term.build_token (Mastic.Error.loc (snd x) b e)
    | N N_clause_hd_open_term ->
        Ast.Term.build_token (Mastic.Error.loc (snd x) b e)
    | N N_binder_body -> let _, _, t = x in term t
    | N N_binder_body_no_ty -> let _, _, t = x in term t
    | N N_list_closed_term_ ->
        all term x b e
    | N N_nonempty_list_closed_term_ ->
        all term x b e
    | N N_list_items ->
        all term x b e
    | N N_list_items_tail ->
        all term x b e
    | N N_type_term ->
        Ast.TypeExpression.build_token (Mastic.Error.loc x b e)
    | N N_atype_term ->
        Ast.TypeExpression.build_token (Mastic.Error.loc x b e)
    | N N_fotype_term ->
        Ast.TypeExpression.build_token (Mastic.Error.loc x b e)
    | N N_kind_term ->
        Ast.TypeExpression.build_token (Mastic.Error.loc x b e)
    | N N_anonymous_pred ->
        Ast.TypeExpression.build_token (Mastic.Error.loc x b e)
    | N N_nonempty_list_atype_term_ -> all ty x b e
    | N N_separated_nonempty_list_CONJ_fotype_term_ -> all ty x b e
    | N N_loption_separated_nonempty_list_CONJ_fotype_term__ -> all ty x b e
    | N N_option_type_term_ -> (match x with Some t -> ty t | None -> text "" b e)
    | N N_pred_item -> ty (snd x)
    | N N_attribute -> Ast.attribute_build_token (Mastic.Error.loc x b e)
    | N N_attributes ->
        all (fun a -> Ast.attribute_build_token (Mastic.Error.loc a b e)) x b e
    | N N_separated_nonempty_list_COLON_attribute_ ->
        all (fun a -> Ast.attribute_build_token (Mastic.Error.loc a b e)) x b e
    | N N_pred_or_func ->
        all (fun a -> Ast.attribute_build_token (Mastic.Error.loc a b e)) x b e
    | N N_constant ->
        text (Ast.Func.show x) b e
    | N N_infix_SYMB ->
        text (Ast.Func.show x) b e
    | N N_prefix_SYMB ->
        text (Ast.Func.show x) b e
    | N N_postfix_SYMB ->
        text (Ast.Func.show x) b e
    | N N_mixfix_SYMB ->
        text (Ast.Func.show x) b e
    | N N_constant_w_loc -> text (Ast.Func.show (fst x)) b e
    | N N_list_constant_ ->
        text (String.concat ", " (List.map Ast.Func.show x)) b e
    | N N_separated_nonempty_list_CONJ_constant_ ->
        text (String.concat ", " (List.map Ast.Func.show x)) b e
    | N N_filename -> text x b e
    | N N_accumulate -> text x b e
    | N N_external_ref -> text x b e
    | N N_separated_nonempty_list_CONJ_filename_ -> text (String.concat ", " x) b e
    | _ -> text "" b e)

  let is_term =
    let open Grammar.MenhirInterpreter in
    function X (N N_term), _,_,_ -> true | _ -> false

  (* the state waits for a term or a type: an item expects one next, and no
     item is complete *)
  let expects_term_or_type productions =
    let open Grammar.MenhirInterpreter in
    let next (_, rhs, _, pos) = List.nth_opt rhs pos in
    List.for_all (fun i -> next i <> None) productions &&
    List.exists (fun i -> match next i with
      | Some (X (N (N_term | N_term_noconj | N_closed_term | N_head_term
                   | N_type_term | N_atype_term | N_fotype_term | N_kind_term))) -> true
      | _ -> false) productions

  let is_decl_start =
    let open Grammar.MenhirInterpreter in
    function
    | X (N N_decl), _,_,0 -> true
    (* after a declaration, the kernel item is program -> decl . program *)
    | X (N N_program), _,_,1 -> true
    | _ -> false

  let default_strategy ?(line_ends = false) ~productions ~next_token ~acceptable_tokens
      ~reducible_productions ~generation_streak () =
    let open Mastic.ErrorResilientParser in
    (* finish the current declaration: reduce if possible, otherwise insert
       the final dot or a closing bracket if it fits, otherwise try the dot
       anyway (Menhir may accept it after empty reductions, that Mastic does
       not list), then a hole for a missing term, and finally make the
       declaration an error *)
    let finish () =
      match reducible_productions with
      | p :: _ -> Reduce p
      | [] ->
      match List.find_opt (fun x -> x.t = Tokens.FULLSTOP) acceptable_tokens, acceptable_tokens with
      | Some x, _ | None, x :: _ -> GenerateToken x
      | None, [] ->
          if next_token.t <> Tokens.FULLSTOP then
            GenerateToken { s = "."; t = Tokens.FULLSTOP; b = next_token.b; e = next_token.b }
          else if generation_streak <= 1 then GenerateHole
          else
            let b = next_token.b in
            GenerateToken { s = "(error)"; b; e = b;
              t = Tokens.DECL_ERROR_TOKEN Mastic.Error.(mkLexError (loc decl_marker b b)) } in
    if generation_streak >= 10 || List.exists is_decl_start productions then TurnIntoError
    else if reducible_productions = [] && generation_streak = 0 && expects_term_or_type productions then
      (* a term (or a type) is missing: an error node takes its place, as
         in X is + 2, read X is Err + 2 *)
      GenerateHole
    else match next_token.t with
    | Tokens.FULLSTOP | Tokens.EOF -> finish ()
    | t when restart_point t next_token.b -> finish ()
    (* new: the token ends its line, and the next line looks like a new declaration *)
    | _ when line_ends -> finish ()
    | _ ->
    match reducible_productions with
    | p :: _ when List.exists is_term productions -> Reduce p
    | _ -> TurnIntoError

  (* Looking ahead (new): the input is lexed upfront, and Mastic can
     simulate a repair on the following tokens. The actions that make sense
     here are tried, each followed by the recovery for the next
     [lookahead_limit] tokens, and the one that loses the fewest tokens of
     the input into errors wins; the default strategy is kept unless another
     action is clearly better (by a token). ELPI_LOOKAHEAD=0 turns the search
     off, ELPI_LOOKAHEAD_DEBUG=1 prints the choices. *)
  let lookahead_limit = try int_of_string (Sys.getenv "ELPI_LOOKAHEAD") with _ -> 10
  let debug_choice = Sys.getenv_opt "ELPI_LOOKAHEAD_DEBUG" <> None

  (* the tokens skipped, reported as errors by resilient_parse *)
  let skipped : token Mastic.ErrorResilientParser.tok list ref = ref []
  let skipped_message = "skipped "

  let show_action = let open Mastic.ErrorResilientParser in function
    | TurnIntoError | TurnIntoThisError _ -> "error" | GenerateHole -> "hole" | Skip -> "skip"
    | GenerateToken t -> "insert " ^ t.s
    | Reduce p -> "reduce" ^ string_of_int (Grammar.MenhirInterpreter.production_index p)

  (* the cost of a simulation: a token of the input lost in an error costs
     10, an inserted token 1; a simulation that does not reach its horizon
     (it seems to loop) is out *)
  let cost (r : Mastic.ErrorResilientParser.simulation) =
    if r.shifted < 0 then max_int
    else (if r.completed then 0 else 1000) + 10 * r.lost + r.inserted
  let margin = 10

  (* bracket balance on the tokens ahead: the first closing bracket that is
     not matched before the end of the declaration (the next dot outside
     brackets), if any *)
  let unmatched_closer_ahead la (next : token Mastic.ErrorResilientParser.tok) =
    let ahead k = (Mastic.ErrorResilientParser.ahead la k).t in
    let rec scan k t depth =
      if k > 5000 then None else
      match t with
      | Tokens.LPAREN | Tokens.LBRACKET | Tokens.LCURLY -> scan (k + 1) (ahead k) (depth + 1)
      | Tokens.RPAREN | Tokens.RBRACKET | Tokens.RCURLY ->
          if depth = 0 then Some t else scan (k + 1) (ahead k) (depth - 1)
      | Tokens.FULLSTOP when depth = 0 -> None
      | Tokens.EOF -> None
      | _ -> scan (k + 1) (ahead k) depth in
    scan 0 next.t 0

  (* the unexpected token ends its line, and the next line starts at column
     0: likely a new declaration (unless the token asks for a continuation) *)
  let line_ends la (next : token Mastic.ErrorResilientParser.tok) =
    let n = Mastic.ErrorResilientParser.ahead la 0 in
    n.b.pos_lnum > next.e.pos_lnum && n.b.pos_cnum = n.b.pos_bol && n.t <> Tokens.EOF &&
    match next.t with
    | Tokens.LPAREN | Tokens.LBRACKET | Tokens.LCURLY | Tokens.VDASH | Tokens.CONJ | Tokens.CONJ2
    | Tokens.PIPE | Tokens.BIND | Tokens.OR | Tokens.ARROW | Tokens.IFF | Tokens.COLON -> false
    | _ -> true

  let handle_unexpected_token ~productions ~next_token ~acceptable_tokens
      ~reducible_productions ~generation_streak ~lookahead =
    let open Mastic.ErrorResilientParser in
    let default = default_strategy ~line_ends:(line_ends lookahead next_token) ~productions ~next_token
      ~acceptable_tokens ~reducible_productions ~generation_streak () in
    let action =
      (* no search when giving up after too many insertions (it could loop) *)
      if lookahead.in_simulation || lookahead_limit <= 0 || generation_streak >= 10 then default else
      (* a dot ends a declaration: it is not turned into an error or skipped
         (unless by the default strategy), the damage could show after the
         horizon of the simulation *)
      let dot = next_token.t = Tokens.FULLSTOP in
      (* a closer is not inserted when the same closer comes later *)
      let later = unmatched_closer_ahead lookahead next_token in
      let candidates =
        default :: (if dot then [] else [TurnIntoError]) @ GenerateHole ::
        (if dot || next_token.t = Tokens.EOF then [] else [Skip]) @
        (List.filter (fun (t : token tok) -> Some t.t <> later) acceptable_tokens
         |> List.map (fun t -> GenerateToken t)) @
        List.map (fun p -> Reduce p) reducible_productions in
      let same a b = match a, b with
        | Reduce p, Reduce q ->
            Grammar.MenhirInterpreter.(production_index p = production_index q)
        | GenerateToken t, GenerateToken u -> t.s = u.s
        | TurnIntoThisError _, _ | _, TurnIntoThisError _ -> false
        | _ -> show_action a = show_action b in
      let candidates = List.fold_left (fun acc a ->
        if List.exists (same a) acc then acc else a :: acc) [] candidates |> List.rev in
      (* the semantic actions run in the simulations may defer errors *)
      let saved = !Ast.Term.deferred in
      let scored = List.map (fun a ->
        let r = lookahead.simulate ~limit:lookahead_limit [a] in
        Ast.Term.deferred := saved;
        a, cost r) candidates in
      let best = List.fold_left (fun (a, c) (a', c') -> if c' < c then (a', c') else (a, c))
        (List.hd scored) scored in
      let best = if snd best < 1000 && snd best + margin <= snd (List.hd scored) then best
        else List.hd scored in
      if debug_choice then
        Printf.eprintf "at %d %S: %s -> %s\n%!" next_token.b.pos_cnum next_token.s
          (String.concat ", " (List.map (fun (a, c) -> Printf.sprintf "%s:%d" (show_action a) c) scored))
          (show_action (fst best));
      fst best in
    (match action with
     | Skip when not lookahead.in_simulation -> skipped := next_token :: !skipped
     | _ -> ());
    action
end

module ErProgram = Mastic.ErrorResilientParser.MakeLookahead(Grammar.MenhirInterpreter)(ProgramParser)(Recovery)

let () = Mastic.ErrorResilientParser.debug := Sys.getenv_opt "MASTIC_DEBUG" <> None

(* consecutive declaration errors are merged into one *)
let rec merge_errors = function
  | Ast.Program.Error x :: Ast.Program.Error y :: rest -> merge_errors (Ast.Program.Error (Mastic.Error.merge x y) :: rest)
  | d :: rest -> d :: merge_errors rest
  | [] -> []

(* One resilient parse: the lexer returns error tokens and the semantic
   actions defer their errors; these errors are added to the ones of Mastic,
   one per position. An accumulate parses (normally) another file in the
   middle of this one, hence the saving of the flags. *)
(* Brackets left open in the head of a clause. In a declaration whose ( or [
   are still open at its final dot (never the case in a valid program: a dot
   cannot be inside parentheses or brackets), the brackets opened before the
   first :- and never closed are closed just before it: in
   p [X|Y :- q X.  the list is the argument of p, not  [X | (Y :- q X)].
   The tokens inserted are returned as completions. *)
let close_brackets_in_head (tokens : Tokens.token Mastic.ErrorResilientParser.tok array) =
  let open Mastic.ErrorResilientParser in
  let inserts = ref [] in  (* (index, tokens to insert before it) *)
  let closer = function
    | Tokens.LPAREN -> { s = ")"; t = Tokens.RPAREN; b = Lexing.dummy_pos; e = Lexing.dummy_pos }
    | _ -> { s = "]"; t = Tokens.RBRACKET; b = Lexing.dummy_pos; e = Lexing.dummy_pos } in
  (* stack: the open brackets (token, index); neck: the first :- with the
     brackets open at that point *)
  let rec scan i stack neck =
    if i < Array.length tokens then
      match tokens.(i).t with
      | Tokens.LPAREN | Tokens.LBRACKET -> scan (i + 1) ((tokens.(i).t, i) :: stack) neck
      | Tokens.RPAREN | Tokens.RBRACKET ->
          let t = tokens.(i).t in
          (match stack with
           | (o, _) :: stack' when (o = Tokens.LPAREN) = (t = Tokens.RPAREN) -> scan (i + 1) stack' neck
           | _ -> scan (i + 1) stack neck)
      | Tokens.VDASH when neck = None -> scan (i + 1) stack (Some (i, stack))
      | Tokens.FULLSTOP | Tokens.EOF ->
          (match neck with
           | Some (j, open_at_neck) when open_at_neck <> [] ->
               (* the brackets open at the neck and still open now *)
               let still = List.filter (fun x -> List.mem x stack) open_at_neck in
               if still <> [] then
                 let b = if j > 0 then tokens.(j - 1).e else tokens.(j).b in
                 inserts := (j, List.map (fun (o, _) -> { (closer o) with b; e = b }) still) :: !inserts
           | _ -> ());
          scan (i + 1) [] None
      | _ -> scan (i + 1) stack neck in
  scan 0 [] None;
  if !inserts = [] then tokens, [] else
  let out = ref [] in
  Array.iteri (fun i t ->
    (match List.assoc_opt i !inserts with Some l -> out := List.rev_append l !out | None -> ());
    out := t :: !out) tokens;
  Array.of_list (List.rev !out),
  List.concat_map (fun (_, l) -> List.map (fun t -> t.b, t.s) l) !inserts

let resilient_parse lexbuf =
  let saved = !Lexer.recovering, !Lexer.errors, !Ast.Term.deferring, !Ast.Term.deferred in
  let restore () =
    let r, l, d, dl = saved in
    Lexer.recovering := r; Lexer.errors := l; Ast.Term.deferring := d; Ast.Term.deferred := dl in
  Lexer.recovering := true; Lexer.errors := []; Ast.Term.deferring := true; Ast.Term.deferred := [];
  Recovery.skipped := [];
  let errs, comps, ast = Fun.protect ~finally:restore (fun () ->
    let start = lexbuf.Lexing.lex_curr_p in
    let tokens, closed = close_brackets_in_head (ErProgram.lex lexbuf) in
    let errs, comps, ast = ErProgram.parse_tokens start tokens in
    let comps = if closed = [] then comps else
      List.stable_sort (fun (p, _) (q, _) -> compare q.Lexing.pos_cnum p.Lexing.pos_cnum) (closed @ comps) in
    let lexing_pos { Util.Loc.source_name; line; line_starts_at; source_start; _ } =
      { Lexing.pos_fname = source_name; pos_lnum = line; pos_bol = line_starts_at; pos_cnum = source_start } in
    let sem = List.filter_map (function
      | Ast.Term.NotInProlog(loc,m) | Parser_config.ParseError(loc,m) ->
          Some (Mastic.ErrorResilientParser.LexError(lexing_pos loc, m))
      | Failure m -> Some (Mastic.ErrorResilientParser.LexError(lexbuf.Lexing.lex_start_p, m))
      | _ -> None) !Ast.Term.deferred in
    let lex = List.map (fun (p,m) -> Mastic.ErrorResilientParser.LexError(p,m)) !Lexer.errors in
    (* the tokens skipped by the recovery *)
    let skipped = List.map (fun t ->
      Mastic.ErrorResilientParser.(LexError(t.b, Recovery.skipped_message ^ t.s))) !Recovery.skipped in
    sem @ lex @ errs @ skipped, comps, ast) in
  (* errs is in reverse order, as returned by Mastic *)
  let pos = function Mastic.ErrorResilientParser.LexError(p,_) | ParseError(p,_) -> p.Lexing.pos_cnum in
  let errs = List.stable_sort (fun x y -> compare (pos y) (pos x)) errs in
  let rec dedup = function
    | x :: (y :: _ as rest) when pos x = pos y -> dedup (x :: List.tl rest)
    | x :: rest -> x :: dedup rest
    | [] -> [] in
  List.rev (dedup (List.rev errs)), comps, merge_errors ast

(* When there are errors, the text is parsed a second time with strings that
   cannot span lines: a string whose closing quote is missing otherwise runs
   to the next string, maybe far away. The result with more declarations that
   are not errors is kept. The lexbuf must hold the whole text. *)
let program_resilient lexbuf =
  let copy = { lexbuf with Lexing.lex_buffer = Bytes.copy lexbuf.Lexing.lex_buffer } in
  let errs, comps, ast = resilient_parse lexbuf in
  if errs = [] && comps = [] then errs, comps, ast else
  let good ast = List.length (List.filter (function Ast.Program.Error _ -> false | _ -> true) ast) in
  Lexer.single_line_strings := true;
  let errs2, comps2, ast2 =
    Fun.protect ~finally:(fun () -> Lexer.single_line_strings := false) (fun () -> resilient_parse copy) in
  if good ast2 > good ast then errs2, comps2, ast2 else errs, comps, ast

(* ------------------------------------------------------------------------- *)

let already_parsed = Hashtbl.create 11

let cleanup_fname filename = Re.Str.replace_first (Re.Str.regexp "/_build/[^/]+") "" filename

let parse_one_file digest filename =
  if Hashtbl.mem already_parsed digest then
    Hashtbl.find already_parsed digest
  else 
    let ic = open_in filename in
    let lexbuf = Lexing.from_channel ic in
    let dest = cleanup_fname filename in
    lexbuf.Lexing.lex_curr_p <- { lexbuf.lex_curr_p with pos_fname = dest };
    let ast = parse Grammar.Incremental.program lexbuf in
    let output = { Ast.file_name = filename; deps = []; digest; ast } in
    Hashtbl.add already_parsed digest output;
    close_in ic;
    output

let () =
  parse_ref := (fun ?cwd filename ->
  let filename = C.resolver ?cwd ~unit:filename () in
  let digest = Digest.file filename in
  if Filename.extension filename = ".mod" then
    (* Teyjus compatibility *)
    let sig_filename = Filename.chop_extension filename ^ ".sig" in
    if Sys.file_exists sig_filename then
      let ds = Digest.file sig_filename in
      let s = parse_one_file ds sig_filename in
      let m = parse_one_file digest filename in
      { Ast.file_name = filename; digest = Digest.string (ds^digest); deps = []; ast = s.ast @ m.ast  }
    else parse_one_file digest filename
  else parse_one_file digest filename)

let to_lexing_loc { Util.Loc.source_name; line; line_starts_at; source_start; _ } =
  { Lexing.pos_fname = source_name;
    pos_lnum = line;
    pos_bol = line_starts_at;
    pos_cnum = source_start; }
  
let lexing_set_position lexbuf loc =
  Option.iter ParseFile.set_current_clent_loc_pyload loc.Util.Loc.client_payload;
  let loc = to_lexing_loc loc in
  let open Lexing in
  lexbuf.lex_abs_pos <- loc.pos_cnum;
  lexbuf.lex_start_p <- loc;
  lexbuf.lex_curr_p <- loc
  
let goal_from ~loc lexbuf =
  lexing_set_position lexbuf loc;
  parse Grammar.Incremental.goal lexbuf
      
let goal ~loc ~text =
  let lexbuf = Lexing.from_string text in
  goal_from ~loc lexbuf

let program_from ~loc ~digest lexbuf =
  Hashtbl.clear already_parsed;
  lexing_set_position lexbuf loc;
  let ast = parse Grammar.Incremental.program lexbuf in
  let filename = let open Util.Loc in
    Printf.sprintf "%s:%d:%d" loc.source_name loc.source_stop lexbuf.Lexing.lex_curr_pos in
  { Ast.file_name = filename; deps = []; digest; ast }


let program ~file =
  Hashtbl.clear already_parsed;
  !parse_ref file

module Internal = struct
let infix_SYMB = Grammar.infix_SYMB
let prefix_SYMB = Grammar.prefix_SYMB
let postfix_SYMB = Grammar.postfix_SYMB
let program_resilient = program_resilient
end

end