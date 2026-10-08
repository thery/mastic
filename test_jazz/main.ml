(* The test driver of test/ (main.ml) for the Jasmin grammar, as
   test_elpi/main.ml.

   main.exe [-fuzz N] [-rands R1,R2,..] [-only N] [-debug] [FILE]

   parses a Jasmin program (FILE, or stdin) with the error-resilient parser
   and prints, as test/main.exe: the input, the errors underlined, the tokens
   inserted by the recovery, and the AST (one item or instruction per line,
   expressions as s-expressions, error nodes as Err«source text»). With
   -fuzz N, the input is fuzzed N times (one character replaced by ';', ' '
   or '$'), and "note: not a subterm" is printed when the AST of the fuzzed
   input is not included in the original one (an error node is included in
   anything).

   main.exe -ref GOOD FILE   the result for FILE, and the measure against GOOD
   main.exe -raw FILE        machine readable output, for recov.py
   main.exe -strict FILE     the normal path of Jasmin (no recovery) *)

open Jazz_parser
open Syntax
module L = Location

let one_line s = String.map (function '\n' | '\t' | '\r' -> ' ' | c -> c) s

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

let sexp l = "(" ^ String.concat " " l ^ ")"
let id (x : Annotations.pident) = L.unloc x

let rec pp_expr (e : pexpr) =
  match L.unloc e with
  | PEParens e -> pp_expr e
  | PEVar x -> id x
  | PEGet (_, aa, ws, x, i, len) ->
      id x ^ (if aa = Warray_.AAdirect then "." else "") ^ "["
      ^ (match ws with Some ws -> string_of_swsize_ty (L.unloc ws) ^ " " | None -> "")
      ^ pp_expr i ^ (match len with Some l -> " : " ^ pp_expr l | None -> "") ^ "]"
  | PEFetch m -> pp_mem m
  | PEpack (sv, es) -> sexp (("pack" ^ string_of_svsize sv) :: List.map pp_expr es)
  | PEstring s -> Printf.sprintf "%S" s
  | PEBool b -> string_of_bool b
  | PEInt i -> i
  | PECall (f, args) | PECombF (f, args) -> sexp (id f :: List.map pp_expr args)
  | PEPrim (f, args) -> sexp (("#" ^ id f) :: List.map pp_expr args)
  | PEOp1 (o, e) -> sexp [ string_of_peop1 o; pp_expr e ]
  | PEOp2 (o, (a, b)) -> sexp [ string_of_peop2 o; pp_expr a; pp_expr b ]
  | PEIf (a, b, c) -> sexp [ "?"; pp_expr a; pp_expr b; pp_expr c ]
  | PEError x -> pp_err "expr" x

and pp_mem (_, ws, e) =
  "[" ^ (match ws with Some ws -> ":" ^ string_of_swsize_ty (L.unloc ws) ^ " " | None -> "") ^ pp_expr e ^ "]"

let pp_type (t : ptype) =
  match L.unloc t with
  | TBool -> "bool"
  | TInt -> "int"
  | TWord ws -> string_of_swsize_ty ws
  | TArray (st, e) -> string_of_sizetype st ^ "[" ^ pp_expr e ^ "]"
  | TAlias x -> id x
  | TError x -> pp_err "type" x

let pp_stotype (sto, ty) = pp_storage sto ^ " " ^ pp_type ty

let pp_lvalue (lv : plvalue) =
  match L.unloc lv with
  | PLIgnore -> "_"
  | PLVar x -> id x
  | PLArray (al, aa, ws, x, e, len) -> pp_expr (L.mk_loc (L.loc lv) (PEGet (al, aa, ws, x, e, len)))
  | PLMem m -> pp_mem m
  | PLError x -> pp_err "lvalue" x

let pp_annotations (a : pannotations) =
  if a = [] then "" else "#[" ^ String.concat ", " (List.map (fun (k, _) -> id k) a) ^ "] "

let string_of_peqop (o : peqop) =
  match o with
  | `Raw -> "="
  | (`Add _ | `Sub _ | `Mul _ | `Div _ | `Mod _ | `ShR _ | `ROR _ | `ROL _ | `ShL _
    | `BAnd _ | `BXOr _ | `BOr _) as o -> string_of_peop2 (o :> peop2) ^ "="

(* an instruction: its line, then its blocks indented *)
let rec pp_instr indent ((a, i) : pinstr) =
  let line s = [ indent ^ pp_annotations a ^ s ] in
  let block b = List.concat_map (pp_instr (indent ^ "  ")) (L.unloc b) in
  match L.unloc i with
  | PIArrayInit x -> line ("ArrayInit(" ^ id x ^ ")")
  | PIAssign ((_, lvs), o, e, c) ->
      line (String.concat ", " (List.map pp_lvalue lvs) ^ (if lvs = [] then "" else " ")
            ^ string_of_peqop o ^ " " ^ pp_expr e ^ (match c with Some c -> " if " ^ pp_expr c | None -> ""))
  | PIAssert (m, e) -> line ("assert " ^ Printf.sprintf "%S" (id m) ^ " " ^ pp_expr e)
  | PIIf (c, b1, b2) ->
      line ("if " ^ pp_expr c) @ block b1
      @ (match b2 with Some b -> [ indent ^ "else" ] @ block b | None -> [])
  | PIFor (v, (d, e1, e2), b) ->
      line ("for " ^ id v ^ " = " ^ pp_expr e1 ^ (if d = `Up then " to " else " downto ") ^ pp_expr e2) @ block b
  | PIWhile (b1, c, b2) ->
      line "while" @ (match b1 with Some b -> block b | None -> [])
      @ [ indent ^ "(" ^ pp_expr c ^ ")" ] @ (match b2 with Some b -> block b | None -> [])
  | PIdecl (st, vs) -> line (pp_stotype st ^ " " ^ String.concat " " (List.map id vs))
  | PIdeclinit (st, l) ->
      line (pp_stotype st ^ " " ^ String.concat ", " (List.map (fun d -> let x, e = L.unloc d in id x ^ " = " ^ pp_expr e) l))
  | PIError x -> line (pp_err "instr" x)
  | PIErrorBlock (x, b) -> line (pp_err "head" x) @ block b

let rec pp_item indent (it : pitem L.located) =
  match L.unloc it with
  | PFundef f ->
      let args = List.map (fun (a, (st, vs)) -> pp_annotations a ^ pp_stotype st ^ " " ^ String.concat " " (List.map id vs)) f.pdf_args in
      let rty = match f.pdf_rty with
        | None -> ""
        | Some l -> " -> " ^ String.concat ", " (List.map (fun (a, st) -> pp_annotations a ^ pp_stotype st) l) in
      [ indent ^ pp_annotations f.pdf_annot
        ^ (match f.pdf_cc with Some `Export -> "export " | Some `Inline -> "inline " | None -> "")
        ^ "fn " ^ id f.pdf_name ^ "(" ^ String.concat ", " args ^ ")" ^ rty ]
      @ pp_body indent f.pdf_body
  | PParam p -> [ indent ^ "param " ^ pp_type p.ppa_ty ^ " " ^ id p.ppa_name ^ " = " ^ pp_expr p.ppa_init ]
  | PGlobal g ->
      [ indent ^ pp_annotations g.pgd_annot ^ "global " ^ pp_type g.pgd_type ^ " " ^ id g.pgd_name ^ " = "
        ^ (match g.pgd_val with GEexpr e -> pp_expr e | GEarray l -> "{" ^ String.concat ", " (List.map pp_expr l) ^ "}") ]
  | Pexec e ->
      [ indent ^ "exec " ^ id e.pex_name ^ " " ^ String.concat ", " (List.map (fun (a, b) -> a ^ ":" ^ b) e.pex_mem) ]
  | Prequire (f, l) ->
      [ indent ^ (match f with Some f -> "from " ^ id f ^ " " | None -> "") ^ "require "
        ^ String.concat " " (List.map (fun s -> Printf.sprintf "%S" (L.unloc s)) l) ]
  | PNamespace (n, l) -> [ indent ^ "namespace " ^ id n ^ " {" ] @ List.concat_map (pp_item (indent ^ "  ")) l @ [ indent ^ "}" ]
  | PTypeAlias (n, a, t) -> [ indent ^ pp_annotations a ^ "type " ^ id n ^ " = " ^ pp_type t ]
  | PError x -> [ indent ^ "error " ^ pp_err "item" x ]
  | PFunError (x, body) -> [ indent ^ "fn " ^ pp_err "header" x ] @ pp_body indent body

and pp_body indent body =
  List.concat_map (pp_instr (indent ^ "  ")) body.pdb_instr
  @ (match L.unloc body.pdb_ret with
     | Some vs -> [ indent ^ "  return " ^ String.concat ", " (List.map id vs) ]
     | None -> [])

let pp_items ast = List.concat_map (pp_item "") ast

(* ------------------------------------------------------------------------ *)
(* The AST as a tree of labelled nodes, with their location: for the
   inclusion of ASTs (-fuzz) and for the measure (-ref, -raw). Error nodes
   are leaves; parentheses are not nodes. *)

type tree = N of string * L.t * tree list | E

let rec t_expr (e : pexpr) =
  let n l k = N (l, L.loc e, k) in
  match L.unloc e with
  | PEParens e -> t_expr e
  | PEVar x -> n ("var:" ^ id x) []
  | PEGet (_, aa, ws, x, i, len) ->
      n ("get:" ^ id x ^ (if aa = Warray_.AAdirect then "." else "")
         ^ (match ws with Some ws -> ":" ^ string_of_swsize_ty (L.unloc ws) | None -> ""))
        (t_expr i :: Option.to_list (Option.map t_expr len))
  | PEFetch (_, ws, i) ->
      n ("fetch" ^ (match ws with Some ws -> ":" ^ string_of_swsize_ty (L.unloc ws) | None -> "")) [ t_expr i ]
  | PEpack (sv, es) -> n ("pack:" ^ string_of_svsize sv) (List.map t_expr es)
  | PEstring s -> n ("string:" ^ s) []
  | PEBool b -> n ("bool:" ^ string_of_bool b) []
  | PEInt i -> n ("int:" ^ i) []
  | PECall (f, args) | PECombF (f, args) -> n ("call:" ^ id f) (List.map t_expr args)
  | PEPrim (f, args) -> n ("prim:" ^ id f) (List.map t_expr args)
  | PEOp1 (o, e) -> n ("op1:" ^ string_of_peop1 o) [ t_expr e ]
  | PEOp2 (o, (a, b)) -> n ("op2:" ^ string_of_peop2 o) [ t_expr a; t_expr b ]
  | PEIf (a, b, c) -> n "?:" [ t_expr a; t_expr b; t_expr c ]
  | PEError _ -> E

let t_type (t : ptype) =
  let n l k = N ("type:" ^ l, L.loc t, k) in
  match L.unloc t with
  | TBool -> n "bool" []
  | TInt -> n "int" []
  | TWord ws -> n (string_of_swsize_ty ws) []
  | TArray (st, e) -> n (string_of_sizetype st ^ "[]") [ t_expr e ]
  | TAlias x -> n (id x) []
  | TError _ -> E

let t_ident kind (x : Annotations.pident) = N (kind ^ ":" ^ id x, L.loc x, [])
let t_stotype (sto, ty) = N ("storage:" ^ pp_storage sto, L.loc ty, [ t_type ty ])
let t_annots (a : pannotations) = List.map (fun (k, _) -> t_ident "annot" k) a

let t_lvalue (lv : plvalue) =
  let n l k = N ("lv:" ^ l, L.loc lv, k) in
  match L.unloc lv with
  | PLIgnore -> n "_" []
  | PLVar x -> n ("var:" ^ id x) []
  | PLArray (_, _, _, x, e, len) -> n ("get:" ^ id x) (t_expr e :: Option.to_list (Option.map t_expr len))
  | PLMem (_, _, e) -> n "mem" [ t_expr e ]
  | PLError _ -> E

let rec t_instr ((a, i) : pinstr) =
  let n l k = N ("instr:" ^ l, L.loc i, t_annots a @ k) in
  let block (b : pblock) = N ("block", L.loc b, List.map t_instr (L.unloc b)) in
  match L.unloc i with
  | PIArrayInit x -> n "arrayinit" [ t_ident "var" x ]
  | PIAssign ((_, lvs), o, e, c) ->
      n ("assign:" ^ string_of_peqop o) (List.map t_lvalue lvs @ [ t_expr e ] @ Option.to_list (Option.map t_expr c))
  | PIAssert (m, e) -> n "assert" [ t_expr e ]
  | PIIf (c, b1, b2) -> n "if" ([ t_expr c; block b1 ] @ Option.to_list (Option.map block b2))
  | PIFor (v, (d, e1, e2), b) ->
      n (if d = `Up then "for:to" else "for:downto") [ t_ident "var" v; t_expr e1; t_expr e2; block b ]
  | PIWhile (b1, c, b2) ->
      n "while" (Option.to_list (Option.map block b1) @ [ t_expr c ] @ Option.to_list (Option.map block b2))
  | PIdecl (st, vs) -> n "decl" (t_stotype st :: List.map (t_ident "var") vs)
  | PIdeclinit (st, l) ->
      n "declinit" (t_stotype st :: List.concat_map (fun d -> let x, e = L.unloc d in [ t_ident "var" x; t_expr e ]) l)
  | PIError _ -> E
  | PIErrorBlock (_, b) -> n "?" [ E; block b ]

let rec t_item (it : pitem L.located) =
  let n l k = N (l, L.loc it, k) in
  match L.unloc it with
  | PFundef f ->
      n ("fn:" ^ id f.pdf_name)
        (t_annots f.pdf_annot
         @ List.concat_map (fun (a, (st, vs)) -> t_annots a @ t_stotype st :: List.map (t_ident "arg") vs) f.pdf_args
         @ List.concat_map (fun (a, st) -> t_annots a @ [ t_stotype st ]) (Option.value f.pdf_rty ~default:[])
         @ t_body f.pdf_body)
  | PParam p -> n ("param:" ^ id p.ppa_name) [ t_type p.ppa_ty; t_expr p.ppa_init ]
  | PGlobal g ->
      n ("global:" ^ id g.pgd_name)
        (t_annots g.pgd_annot @ [ t_type g.pgd_type ]
         @ (match g.pgd_val with GEexpr e -> [ t_expr e ] | GEarray l -> List.map t_expr l))
  | Pexec e -> n ("exec:" ^ id e.pex_name) []
  | Prequire (f, l) ->
      n "require" (Option.to_list (Option.map (t_ident "from") f)
                   @ List.map (fun s -> N ("file:" ^ L.unloc s, L.loc s, [])) l)
  | PNamespace (x, l) -> n ("namespace:" ^ id x) (List.map t_item l)
  | PTypeAlias (x, a, t) -> n ("typealias:" ^ id x) (t_annots a @ [ t_type t ])
  | PError _ -> E
  | PFunError (_, body) -> n "fn" (E :: t_body body)

and t_body body =
  List.map t_instr body.pdb_instr
  @ (match L.unloc body.pdb_ret with
     | Some vs -> [ N ("return", L.loc body.pdb_ret, List.map (t_ident "var") vs) ]
     | None -> [])

(* ------------------------------------------------------------------------ *)
(* inclusion of ASTs, as Ast.included_prog in test/: an error node is
   included in anything, locations are ignored *)

let rec included x y =
  match x, y with
  | E, _ -> true
  | N (l, _, k), N (l', _, k') -> l = l' && List.length k = List.length k' && List.for_all2 included k k'
  | N _, E -> false

(* the items of the fuzzed program are, in order, included in items of the
   original one *)
let rec included_prog xs ys =
  match xs, ys with
  | [], _ -> true
  | _, [] -> List.for_all (fun x -> x = E) xs
  | x :: xs', y :: ys' -> (included x y && included_prog xs' ys') || included_prog xs ys'

(* ------------------------------------------------------------------------ *)
(* the output of test/main.exe *)

let parse ?(fname = "") input =
  text := input;
  spans := [];
  let lexbuf = Lexing.from_string input in
  lexbuf.Lexing.lex_curr_p <- { lexbuf.lex_curr_p with pos_fname = fname };
  let errs, comps, ast = Parse.resilient lexbuf in
  let printed = pp_items ast in
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
    | Mastic.ErrorResilientParser.LexError (_, m) -> Printf.printf "error: %s lexical error\n" (one_line m)
    | Mastic.ErrorResilientParser.ParseError _ -> ()) errs;
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
   its kind and name (fn:f, instr:assign:=, var:x, op2:+, int:3, type:u64,
   ...) and its span in the source. Error nodes are not counted as nodes:
   they stand for "unknown".

   P1 and P2 differ in one region, delimited by their longest common prefix
   and suffix: [p, q1) in P1, [p, q2) in P2. The positions of P1 are moved to
   P2: before the region they stay, after it they are shifted by q2 - q1, and
   inside it (bounds included) they are unknown, and match any position of
   the region of P2 (bounds included). So the instruction around a damaged
   expression is still expected, whether the edit removed, added or replaced
   text. The nodes lying entirely in the region (text removed from P1, or
   added in P2) are not counted: nothing can be expected of them. A node of
   A2 matches a node of A1 when they have the same label and their bounds
   match.

     recall    = matched / expected nodes (of A1)
                 how much of the good tree is recovered; an error node loses
                 the nodes it replaces
     precision = matched / recovered nodes (of A2, error nodes aside)
                 how much of the recovered tree is right; a wrong structure
                 (two instructions merged, a block closed too early) lowers
                 it, an error node does not
     F1        = 2 * precision * recall / (precision + recall)

   This is the PARSEVAL measure used to evaluate natural language parsers. *)

let nodes_of_ast (ast : pprogram) =
  let acc = ref [] in
  let rec add = function
    | E -> ()
    | N (l, loc, k) -> acc := (l, loc.L.loc_bchar, loc.L.loc_echar) :: !acc; List.iter add k in
  List.iter (fun it -> add (t_item it)) ast;
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
  List.iteri (fun i m ->
    let i = i + 1 in
    if !only_fno < 1 || i = !only_fno then begin
      let fuzzed = fuzz m input in
      let header = Printf.sprintf "fuzzed input #%d: " i in
      let ((_, _, ast', _, _) as r) = parse fuzzed in
      show_result header fuzzed r;
      if not (included_prog (List.map t_item ast') (List.map t_item ast)) then Printf.printf "note: not a subterm\n";
      show_measure (measure (input, ast) (fuzzed, ast'));
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
(* -raw (for recov.py), -ref and -strict *)

let read file = let ic = open_in_bin file in let s = really_input_string ic (in_channel_length ic) in close_in ic; s

let against = ref None

(* one item, without its locations: to compare items in recov.py *)
let rec show_tree = function
  | E -> "Err"
  | N (l, _, []) -> l
  | N (l, _, k) -> "(" ^ String.concat " " (l :: List.map show_tree k) ^ ")"

let raw file =
  let input = read file in
  match parse ~fname:file input with
  | errs, comps, ast, _, spans ->
      List.iter (function
        | Mastic.ErrorResilientParser.LexError (p, m) -> Printf.printf "L\t%d\t%s\n" p.Lexing.pos_cnum (one_line m)
        | Mastic.ErrorResilientParser.ParseError (p, st) -> Printf.printf "E\t%d\t%d\n" p.Lexing.pos_cnum st)
        errs;
      List.iter (fun (p, s) -> Printf.printf "C\t%d\t%s\n" p.Lexing.pos_cnum s) (List.rev comps);
      List.iter (fun (k, b, e) -> Printf.printf "S\t%s\t%d\t%d\n" k b e) spans;
      List.iter (fun (it : pitem L.located) ->
        let kind = match L.unloc it with PError _ -> "Error" | _ -> "Item" in
        (* a PFunError is not an Error: its body is recovered *)
        let b, e = match L.unloc it with
          | PError x -> error_span x
          | _ -> (L.loc it).loc_bchar, (L.loc it).loc_echar in
        Printf.printf "D\t%s\t%d\t%d\t%s\n" kind b e (one_line (show_tree (t_item it)))) ast;
      (* the measure against the good program: expected, recovered, matched *)
      Option.iter (fun good ->
        let good_text = read good in
        let _, _, good_ast, _, _ = parse ~fname:good good_text in
        let m = measure (good_text, good_ast) (input, ast) in
        Printf.printf "M\t%d\t%d\t%d\n" m.expected m.recovered m.matched) !against
  | exception e ->
      Printf.printf "X\t%s\n" (one_line (Printexc.to_string e));
      exit 2

(* -ref GOOD FILE: the result for FILE, and the measure against GOOD *)
let with_reference good file =
  let good_text = read good and input = read file in
  let _, _, good_ast, _, _ = parse good_text in
  let ((_, _, ast, _, _) as r) = parse input in
  show_result "input: " input r;
  show_measure (measure (good_text, good_ast) (input, ast))

(* the normal path of Jasmin: the items, without locations *)
let strict file =
  let lexbuf = Lexing.from_string (read file) in
  match Parse.strict lexbuf with
  | ast -> List.iter (fun it -> print_endline (one_line (show_tree (t_item it)))) ast
  | exception e -> print_endline ("RAISED " ^ Printexc.to_string e)

let () =
  let file = ref None and rands = ref "" and mode = ref `Show in
  Arg.parse
    [
      ("-fuzz", Arg.Set_int fuzz_no, "how many fuzz (default 0)");
      ("-only", Arg.Set_int only_fno, "only run fuzz number N");
      ("-rands", Arg.Set_string rands, "random values (comma separated)");
      ("-debug", Arg.Set Mastic.ErrorResilientParser.debug, "verbose");
      ("-raw", Arg.Unit (fun () -> mode := `Raw), "machine readable output, for recov.py");
      ("-against", Arg.String (fun f -> against := Some f), "GOOD with -raw, the measure against GOOD");
      ("-strict", Arg.Unit (fun () -> mode := `Strict), "the normal path of Jasmin");
      ("-ref", Arg.String (fun f -> mode := `Ref f), "GOOD compare the recovered AST with the one of GOOD");
    ]
    (fun f -> file := Some f)
    "main.exe [options] [FILE]";
  match !mode, !file with
  | `Raw, Some f -> raw f
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
