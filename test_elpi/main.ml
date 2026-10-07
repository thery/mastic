(* The test driver of test/ (main.ml) for the Elpi grammar.

   main.exe [-fuzz N] [-rands R1,R2,..] [-only N] [-debug] [FILE]

   parses an Elpi program (FILE, or stdin) with the error-resilient parser and
   prints, as test/main.exe: the input, the errors underlined, the tokens
   inserted by the recovery, and the AST (terms as s-expressions, error nodes
   as Err«source text»). With -fuzz N, the input is fuzzed N times (one
   character replaced by ';', ' ' or '$'), and "note: not a subterm" is printed
   when the AST of the fuzzed input is not included in the original one (an
   error node is included in anything).

   main.exe -raw FILE [DIR]  one item per line, for recov.py
   main.exe -strict FILE     the normal path of Elpi (no recovery) *)

open Elpi_util
open Elpi_parser
open Ast

let one_line s = String.map (function '\n' | '\t' -> ' ' | c -> c) s

(* ------------------------------------------------------------------------ *)
(* printing the AST *)

let text = ref ""

let slice b e =
  let b = max 0 b and e = min (String.length !text) e in
  if e <= b then "" else String.sub !text b (e - b)

let error_span (e : Mastic.Error.t) =
  let b, e = Mastic.Error.span e in
  (b.Lexing.pos_cnum, e.Lexing.pos_cnum)

(* the error nodes met while printing, with their kind *)
let spans = ref []

let pp_err kind e =
  let b, e' = error_span e in
  spans := (kind, b, e') :: !spans;
  Printf.sprintf "Err«%s»" (one_line (slice b e'))

let rec pp_term (t : Term.t) =
  match t.it with
  | Term.Const f -> Func.show f
  | Term.App (hd, args) -> "(" ^ String.concat " " (List.map pp_term (hd :: args)) ^ ")"
  | Term.Lam (x, _, None, t) -> Func.show x ^ "\\ " ^ pp_term t
  | Term.Lam (x, _, Some ty, t) -> Func.show x ^ ":" ^ pp_type ty ^ "\\ " ^ pp_term t
  | Term.CData c -> Format.asprintf "%a" Util.CData.pp c
  | Term.Quoted { data; _ } -> "{{" ^ data ^ "}}"
  | Term.Cast (t, ty) -> "(" ^ pp_term t ^ " : " ^ pp_type ty ^ ")"
  | Term.Parens t -> pp_term t
  | Term.Err e -> pp_err "term" e

and pp_type : 'a. 'a TypeExpression.t -> string = fun ty ->
  match ty.tit with
  | TypeExpression.TConst c -> Func.show c
  | TypeExpression.TApp (c, t, ts) -> "(" ^ String.concat " " (Func.show c :: List.map pp_type (t :: ts)) ^ ")"
  | TypeExpression.TPred (_, args, _) ->
      "(pred " ^ String.concat ", " (List.map (fun (m, t) ->
        (match m with Util.Mode.Input -> "i:" | Util.Mode.Output -> "o:") ^ pp_type t) args) ^ ")"
  | TypeExpression.TArr (a, b) -> "(" ^ pp_type a ^ " -> " ^ pp_type b ^ ")"
  | TypeExpression.TErr e -> pp_err "type" e

let pp_attributes = function
  | [] -> ""
  | l -> String.concat " " (List.map (function
      | AttributeError e -> ":" ^ pp_err "attribute" e
      | a -> ":" ^ one_line (show_raw_attribute a)) l) ^ " "

let pp_decl (d : Program.decl) =
  match d with
  | Program.Clause { attributes; body; _ } -> "clause " ^ pp_attributes attributes ^ pp_term body
  | Program.Chr { to_match; to_remove; guard; new_goal; _ } ->
      let seq { Chr.conclusion; _ } = pp_term conclusion in
      "rule " ^ String.concat " " (List.map seq to_match)
      ^ (if to_remove = [] then "" else " \\ " ^ String.concat " " (List.map seq to_remove))
      ^ (match guard with None -> "" | Some g -> " | " ^ pp_term g)
      ^ (match new_goal with None -> "" | Some g -> " <=> " ^ seq g)
  | Program.Pred { name; attributes; ty; _ } -> "pred " ^ pp_attributes attributes ^ Func.show name ^ " " ^ pp_type ty
  | Program.Type l -> "type " ^ String.concat ", " (List.map (fun { Type.name; _ } -> Func.show name) l)
      ^ (match l with { ty; _ } :: _ -> " " ^ pp_type ty | [] -> "")
  | Program.Kind l -> "kind " ^ String.concat ", " (List.map (fun { Type.name; _ } -> Func.show name) l)
  | Program.Macro { name; body; _ } -> "macro " ^ Func.show name ^ " " ^ pp_term body
  | Program.TypeAbbreviation { name; _ } -> "typeabbrev " ^ Func.show name
  | Program.Namespace (_, f) -> "namespace " ^ Func.show f ^ " {"
  | Program.Constraint _ -> "constraint {"
  | Program.Begin _ -> "{"
  | Program.End _ -> "}"
  | Program.Shorten _ -> "shorten"
  | Program.Accumulated (_, l) -> "accumulate " ^ String.concat ", " (List.map (fun o -> Filename.basename o.file_name) l)
  | Program.Ignored _ -> "ignored"
  | Program.Error e -> "error " ^ pp_err "decl" e

(* ------------------------------------------------------------------------ *)
(* inclusion of ASTs, as Ast.included_prog in test/: an error node is
   included in anything, locations are ignored *)

let rec included_term (x : Term.t) (y : Term.t) =
  match x.it, y.it with
  | Term.Err _, _ -> true
  | Term.Const a, Term.Const b -> Func.equal a b
  | Term.App (h, l), Term.App (h', l') -> included_term h h' && included_terms l l'
  | Term.Lam (a, _, _, t), Term.Lam (b, _, _, t') -> Func.equal a b && included_term t t'
  | Term.CData a, Term.CData b -> Util.CData.equal a b
  | Term.Quoted a, Term.Quoted b -> a.data = b.data
  | Term.Cast (t, _), Term.Cast (t', _) -> included_term t t'
  | Term.Parens t, _ -> included_term t y
  | _, Term.Parens t' -> included_term x t'
  | _ -> false

and included_terms l l' = List.length l = List.length l' && List.for_all2 included_term l l'

let included_decl (x : Program.decl) (y : Program.decl) =
  match x, y with
  | Program.Error _, _ -> true
  | Program.Clause a, Program.Clause b -> included_term a.body b.body
  | _ ->
      (* the other declarations are compared as printed, error nodes aside *)
      let p d = let s = !spans in let r = pp_decl d in spans := s; r in
      p x = p y

(* the declarations of the fuzzed program are, in order, included in
   declarations of the original one *)
let rec included_prog xs ys =
  match xs, ys with
  | [], _ -> true
  | _, [] -> List.for_all (function Program.Error _ -> true | _ -> false) xs
  | x :: xs', y :: ys' -> (included_decl x y && included_prog xs' ys') || included_prog xs ys'

(* ------------------------------------------------------------------------ *)
(* the output of test/main.exe *)

module P = Parse.Make (struct
  let versions = Util.StrMap.empty
  let resolver = Util.std_resolver ~paths:[ "." ] ()
end)

let parse input =
  text := input;
  spans := [];
  let lexbuf = Lexing.from_string input in
  let errs, comps, ast = P.Internal.program_resilient lexbuf in
  let printed = List.map pp_decl ast in
  (errs, comps, ast, printed, List.rev !spans)

(* each line of the input, with under it the error spans (^) *)
let show_result header input (errs, comps, _, printed, spans) =
  let lines = String.split_on_char '\n' input in
  let pad = String.make (String.length header) ' ' in
  let _ = List.fold_left (fun (start, first) line ->
    let stop = start + String.length line in
    if line <> "" || stop < String.length input then begin
      Printf.printf "%s%s\n" (if first then header else pad) line;
      let marks = Bytes.make (String.length line) ' ' in
      List.iter (fun (_, b, e) ->
        for i = max b start to min e stop - 1 do Bytes.set marks (i - start) '^' done;
        if b = e && start <= b && b < stop then Bytes.set marks (b - start) '^') spans;
      let marks = Bytes.to_string marks in
      if String.trim marks <> "" then
        Printf.printf "%s%s recovered syntax error\n" (String.sub ("error: " ^ pad) 0 (String.length header)) marks
    end;
    (stop + 1, false)) (0, true) lines in
  List.iter (function
    | Mastic.ErrorResilientParser.LexError (p, m) ->
        Printf.printf "error: %s lexical error\n" (one_line m) |> ignore; ignore p
    | Mastic.ErrorResilientParser.ParseError _ -> ()) (List.rev errs);
  List.iter (fun (p, s) ->
    Printf.printf "error: line %d, column %d: completed with %s\n"
      p.Lexing.pos_lnum (p.Lexing.pos_cnum - p.Lexing.pos_bol) s) (List.rev comps);
  Printf.printf "ast:\n";
  List.iter (fun s -> Printf.printf "  %s\n" s) printed;
  flush_all ()

let fuzz_with = [| ';'; ' '; '$' |]
let fuzz_with n = fuzz_with.(n mod Array.length fuzz_with)
let fuzz m l = String.mapi (fun i c -> if i = m then fuzz_with m else c) l

let fuzz_no = ref 0
let only_fno = ref 0

(* ------------------------------------------------------------------------ *)
(* The measure: how much does the AST A2 recovered from a damaged program P2
   look like the AST A1 of the good program P1 it comes from?

   An AST is seen as the set of its nodes, each written (label, start, end):
   its kind and name (clause, app:is, const:X, data:2, tconst:int, pred:q,
   ...) and its span in the source. Error nodes are not counted as nodes:
   they stand for "unknown".

   P1 and P2 differ in one region, delimited by their longest common prefix
   and suffix: [p, q1) in P1, [p, q2) in P2. The positions of P1 are moved to
   P2: before the region they stay, after it they are shifted by q2 - q1, and
   inside it (bounds included) they are unknown, and match any position of
   the region of P2 (bounds included). So the clause around a damaged term is
   still expected, whether the edit removed, added or replaced text. The nodes
   lying entirely in the region (text removed from P1, or added in P2) are
   not counted: nothing can be expected of them. A node of A2 matches a node
   of A1 when they have the same label and their bounds match.

     recall    = matched / expected nodes (of A1)
                 how much of the good tree is recovered; an error node loses
                 the nodes it replaces
     precision = matched / recovered nodes (of A2, error nodes aside)
                 how much of the recovered tree is right; a wrong structure
                 (two clauses merged, the end of a clause read as a clause)
                 lowers it, an error node does not
     F1        = 2 * precision * recall / (precision + recall)

   This is the PARSEVAL measure used to evaluate natural language parsers. *)

let nodes_of_ast (ast : Program.decl list) =
  let acc = ref [] in
  let add l (loc : Util.Loc.t) = acc := (l, loc.source_start, loc.source_stop) :: !acc in
  let rec head (h : Term.t) =
    match h.it with Term.Const f -> Func.show f | Term.Parens h -> head h | Term.Err _ -> "?" | _ -> "_" in
  let rec term (t : Term.t) =
    match t.it with
    | Term.Const f -> add ("const:" ^ Func.show f) t.loc
    | Term.App (h, args) -> add ("app:" ^ head h) t.loc; term h; List.iter term args
    | Term.Lam (x, _, ty, b) -> add ("lam:" ^ Func.show x) t.loc; Option.iter typ ty; term b
    | Term.CData c -> add ("data:" ^ Format.asprintf "%a" Util.CData.pp c) t.loc
    | Term.Quoted q -> add ("quoted:" ^ q.data) t.loc
    | Term.Cast (t', ty) -> add "cast" t.loc; term t'; typ ty
    | Term.Parens t' -> term t'
    | Term.Err _ -> ()
  and typ : 'a. 'a TypeExpression.t -> unit = fun ty ->
    match ty.tit with
    | TypeExpression.TConst c -> add ("tconst:" ^ Func.show c) ty.tloc
    | TypeExpression.TApp (c, t, ts) -> add ("tapp:" ^ Func.show c) ty.tloc; List.iter typ (t :: ts)
    | TypeExpression.TPred (_, args, _) -> add "tpred" ty.tloc; List.iter (fun (_, t) -> typ t) args
    | TypeExpression.TArr (a, b) -> add "tarr" ty.tloc; typ a; typ b
    | TypeExpression.TErr _ -> () in
  let sequent { Chr.eigen; context; conclusion } = term eigen; term context; term conclusion in
  List.iter (function
    | Program.Clause c -> add "clause" c.loc; term c.body
    | Program.Chr r ->
        add "rule" r.loc; List.iter sequent (r.to_match @ r.to_remove);
        Option.iter term r.guard; Option.iter sequent r.new_goal
    | Program.Pred t -> add ("pred:" ^ Func.show t.name) t.loc; typ t.ty
    | Program.Type l -> List.iter (fun (t : _ Type.t) -> add ("type:" ^ Func.show t.name) t.loc; typ t.ty) l
    | Program.Kind l -> List.iter (fun (t : _ Type.t) -> add ("kind:" ^ Func.show t.name) t.loc; typ t.ty) l
    | Program.Macro m -> add ("macro:" ^ Func.show m.name) m.loc; term m.body
    | Program.TypeAbbreviation a -> add ("typeabbrev:" ^ Func.show a.name) a.loc
    | Program.Namespace (loc, f) -> add ("namespace:" ^ Func.show f) loc
    | Program.Constraint (loc, _, _) -> add "constraint" loc
    | Program.Begin loc -> add "begin" loc
    | Program.End loc -> add "end" loc
    | Program.Shorten (loc, _) -> add "shorten" loc
    | Program.Accumulated (loc, _) -> add "accumulate" loc
    | Program.Ignored loc -> add "ignored" loc
    | Program.Error _ -> ()) ast;
  !acc

(* the damaged region: [p, q1) in text1, [p, q2) in text2 *)
let damaged_region text1 text2 =
  let n1 = String.length text1 and n2 = String.length text2 in
  let p = ref 0 in
  while !p < n1 && !p < n2 && text1.[!p] = text2.[!p] do incr p done;
  let s = ref 0 in
  while !s < n1 - !p && !s < n2 - !p && text1.[n1 - 1 - !s] = text2.[n2 - 1 - !s] do incr s done;
  (!p, n1 - !s, n2 - !s)

type measure = { expected : int; recovered : int; matched : int }

let measure (text1, ast1) (text2, ast2) =
  let p, q1, q2 = damaged_region text1 text2 in
  (* a position of text1 seen in text2: None when unknown *)
  let move x = if x < p then Some x else if x > q1 then Some (x + q2 - q1) else None in
  let fits x y = match x with Some x -> x = y | None -> p <= y && y <= q2 in
  let inside p q (_, b, e) = q > p && p <= b && e <= q in
  let expected = List.filter (fun n -> not (inside p q1 n)) (nodes_of_ast ast1) in
  let recovered = List.filter (fun n -> not (inside p q2 n)) (nodes_of_ast ast2) in
  (* each recovered node matches at most one expected node, and conversely *)
  let by_label = Hashtbl.create 97 in
  List.iter (fun (l, b, e) -> Hashtbl.add by_label l (ref false, move b, move e)) expected;
  let matched = List.fold_left (fun m (l, b, e) ->
    match List.find_opt (fun (used, b', e') -> not !used && fits b' b && fits e' e) (Hashtbl.find_all by_label l) with
    | Some (used, _, _) -> used := true; m + 1
    | None -> m) 0 recovered in
  { expected = List.length expected; recovered = List.length recovered; matched }

let percent a b = if b = 0 then 100. else 100. *. float a /. float b

let show_measure { expected; recovered; matched } =
  let precision = percent matched recovered and recall = percent matched expected in
  let f1 = if precision +. recall = 0. then 0. else 2. *. precision *. recall /. (precision +. recall) in
  Printf.printf "measure: precision %.1f%% (%d/%d) recall %.1f%% (%d/%d) F1 %.1f%%\n"
    precision matched recovered recall matched expected f1

let process rands input =
  let header = "input: " in
  let original = parse input in
  show_result header input original;
  Printf.printf "\n";
  let _, _, ast, _, _ = original in
  let original_text = input in
  List.iteri (fun i m ->
    let i = i + 1 in
    if !only_fno < 1 || i = !only_fno then begin
      let input = fuzz m input in
      let header = Printf.sprintf "fuzzed input #%d: " i in
      let ((_, _, ast', _, _) as r) = parse input in
      show_result header input r;
      if not (included_prog ast' ast) then Printf.printf "note: not a subterm\n";
      show_measure (measure (original_text, ast) (input, ast'));
      Printf.printf "\n"
    end) rands

let rec draw_rands user_given how_many bound =
  if how_many = 0 then []
  else
    let r, user_given =
      match user_given with
      | [] -> (Random.int (max 1 (bound - 1)), user_given)
      | x :: user_given -> if x >= bound then exit 2 else (x, user_given)
    in
    r :: draw_rands user_given (how_many - 1) bound

(* ------------------------------------------------------------------------ *)
(* -raw (for recov.py) and -strict *)

let read file = let ic = open_in_bin file in let s = really_input_string ic (in_channel_length ic) in close_in ic; s

(* a parser resolving accumulate in the directory of the file *)
let parser_for dir =
  (module Parse.Make (struct
    let versions = Util.StrMap.empty
    (* only parsing is tested: a file that cannot be found (e.g. a Coq
       logical path of coq-elpi) is read as an empty file *)
    let resolver ?cwd ~unit () =
      try Util.std_resolver ~paths:[ dir ] () ?cwd ~unit () with Failure _ -> "/dev/null"
  end) : Parse.Parser_w_Internals)

let against = ref None

let raw file dir =
  let module P = (val parser_for (Option.value dir ~default:(Filename.dirname file))) in
  let ic = open_in_bin file in
  let input = really_input_string ic (in_channel_length ic) in
  text := input;
  let lexbuf = Lexing.from_string input in
  lexbuf.Lexing.lex_curr_p <- { lexbuf.lex_curr_p with pos_fname = file };
  match P.Internal.program_resilient lexbuf with
  | errs, comps, ast ->
      List.iter (function
        | Mastic.ErrorResilientParser.LexError (p, m) -> Printf.printf "L\t%d\t%s\n" p.Lexing.pos_cnum (one_line m)
        | Mastic.ErrorResilientParser.ParseError (p, st) -> Printf.printf "E\t%d\t%d\n" p.Lexing.pos_cnum st)
        (List.rev errs);
      List.iter (fun (p, s) -> Printf.printf "C\t%d\t%s\n" p.Lexing.pos_cnum s) (List.rev comps);
      spans := [];
      List.iter (fun d -> ignore (pp_decl d)) ast;
      List.iter (fun (k, b, e) -> Printf.printf "S\t%s\t%d\t%d\n" k b e) (List.rev !spans);
      List.iter (fun d -> Printf.printf "D\t%s\n" (one_line (Program.show_decl d))) ast;
      (* the measure against the good program: expected, recovered, matched *)
      Option.iter (fun good ->
        let good_text = read good in
        let module G = (val parser_for (Filename.dirname good)) in
        let lexbuf = Lexing.from_string good_text in
        lexbuf.Lexing.lex_curr_p <- { lexbuf.lex_curr_p with pos_fname = good };
        let _, _, good_ast = G.Internal.program_resilient lexbuf in
        let m = measure (good_text, good_ast) (input, ast) in
        Printf.printf "M\t%d\t%d\t%d\n" m.expected m.recovered m.matched) !against
  | exception e ->
      Printf.printf "X\t%s\n" (one_line (Printexc.to_string e));
      exit 2

(* -ref GOOD FILE: the result for FILE, and the measure against GOOD *)
let with_reference good file =
  let good_text = read good and text = read file in
  let _, _, good_ast, _, _ = parse good_text in
  let ((_, _, ast, _, _) as r) = parse text in
  show_result "input: " text r;
  show_measure (measure (good_text, good_ast) (text, ast))

let strict file =
  let module P = (val parser_for (Filename.dirname file)) in
  match P.program ~file with
  | { ast; _ } -> List.iter (fun d -> print_endline (Program.show_decl d)) ast
  | exception e -> print_endline ("RAISED " ^ Printexc.to_string e)

let () =
  let file = ref None and rands = ref "" and mode = ref `Show and dir = ref None in
  Arg.parse
    [
      ("-fuzz", Arg.Set_int fuzz_no, "how many fuzz (default 0)");
      ("-only", Arg.Set_int only_fno, "only run fuzz number N");
      ("-rands", Arg.Set_string rands, "random values (comma separated)");
      ("-debug", Arg.Set Mastic.ErrorResilientParser.debug, "verbose");
      ("-raw", Arg.Unit (fun () -> mode := `Raw), "machine readable output, for recov.py");
      ("-against", Arg.String (fun f -> against := Some f), "GOOD with -raw, the measure against GOOD");
      ("-strict", Arg.Unit (fun () -> mode := `Strict), "the normal path of Elpi");
      ("-ref", Arg.String (fun f -> mode := `Ref f), "GOOD compare the recovered AST with the one of GOOD");
    ]
    (fun f -> if !file = None then file := Some f else dir := Some f)
    "main.exe [options] [FILE]";
  match !mode, !file with
  | `Raw, Some f -> raw f !dir
  | `Strict, Some f -> strict f
  | `Ref good, Some f -> with_reference good f
  | _ ->
      let ic = match !file with Some f -> open_in_bin f | None -> stdin in
      let input = In_channel.input_all ic in
      let rands =
        String.split_on_char ',' !rands
        |> List.filter_map (fun x -> int_of_string_opt (String.trim x)) in
      let rands = draw_rands rands !fuzz_no (String.length input) in
      if !fuzz_no > 0 then Printf.printf "random: %s\n" (String.concat "," (List.map string_of_int rands));
      process rands input
