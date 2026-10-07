let debug = ref false

let dbg f =
  if !debug then (
    f ();
    flush_all ())
  else ()

let say x = Format.fprintf Format.err_formatter x

type 'token tok = { s : string; t : 'token; b : Lexing.position; e : Lexing.position }

type error =
  | LexError of (Lexing.position * string)
  | ParseError of (Lexing.position * int)

type completion = Lexing.position * string

let tok_to_triple { t; b; e } = (t, b, e)

type ('token, 'production) recovery_action =
  | TurnIntoError
  | TurnIntoThisError of Error.t
  | GenerateHole
  | GenerateToken of 'token tok
  | Reduce of 'production
  | Skip

(* What the recovery sees ahead when the input is lexed upfront: all the
   tokens, where the parser is, and a way to try a repair. *)
type simulation = { shifted : int; lost : int; inserted : int; completed : bool }

let failed_simulation = { shifted = -1; lost = max_int; inserted = max_int; completed = false }

type ('token, 'production) lookahead = {
  tokens : 'token tok array;
  position : int;
  pending : 'token tok list;
  in_simulation : bool;
  simulate : limit:int -> ('token, 'production) recovery_action list -> simulation;
}

let ahead la k =
  let rec nth l k = match l with
    | x :: _ when k = 0 -> x
    | _ :: l -> nth l (k - 1)
    | [] ->
        let n = Array.length la.tokens in
        la.tokens.(min (n - 1) (la.position + k)) in
  nth la.pending k

module type RecoveryCommon = sig
  type token

  val show_token : token -> string

  type 'a symbol
  type xsymbol

  val pp_symbol : 'a option -> Format.formatter -> 'a symbol -> unit

  type 'a terminal
  type 'a env
  type production

  val match_error_token : token -> Error.t option
  val build_error_token : Error.t -> token
  val is_eof_token : token -> bool
  val token_of_terminal : 'a terminal -> (string * token) option
  val reduce_as_parse_error : 'a -> 'a symbol -> Lexing.position -> Lexing.position -> token
end

module type Recovery = sig
  include RecoveryCommon

  val handle_unexpected_token :
    productions:(xsymbol * xsymbol list * production * int) list ->
    next_token:token tok ->
    acceptable_tokens:token tok list ->
    reducible_productions:production list ->
    generation_streak:int ->
    (token, production) recovery_action
end

module type RecoveryLookahead = sig
  include RecoveryCommon

  val handle_unexpected_token :
    productions:(xsymbol * xsymbol list * production * int) list ->
    next_token:token tok ->
    acceptable_tokens:token tok list ->
    reducible_productions:production list ->
    generation_streak:int ->
    lookahead:(token, production) lookahead ->
    (token, production) recovery_action
end

module type IncrementalParser = sig
  type ast
  type 'a checkpoint

  val main : Lexing.position -> ast checkpoint

  type token

  val token : Lexing.lexbuf -> token
end

module MakeLookahead
    (I : MenhirLib.IncrementalEngine.EVERYTHING)
    (M : IncrementalParser with type 'a checkpoint = 'a I.checkpoint and type token = I.token)
    (R :
      RecoveryLookahead
        with type token = I.token
         and type 'a symbol = 'a I.symbol
         and type xsymbol = I.xsymbol
         and type 'a terminal = 'a I.terminal
         and type 'a env = 'a I.env
         and type production = I.production) =
struct
  open I
  open M
  open R
  open Lexing

  let try_pop env = match pop env with Some x -> x | None -> env

  type _ two_errors =
    | Empty
    | TopIsErr : token * 'x env -> 'x two_errors
    | Top2AreErr : token * token * 'x env -> 'x two_errors

  let ensure_top_is_error_token env =
    match top env with
    | None -> None
    | Some (Element (tx, x, b, e)) ->
        let tx = incoming_symbol tx in
        Some (reduce_as_parse_error x tx b e, try_pop env)

  let ensure_top2_are_error_token env =
    match ensure_top_is_error_token env with
    | None -> Empty
    | Some (x, env1) -> (
        match ensure_top_is_error_token env1 with
        | None -> TopIsErr (x, env1)
        | Some (y, env2) -> Top2AreErr (x, y, env2))

  let tail = function [] -> [] | _ :: xs -> xs
  let rec drop n l = if n = 0 then l else drop (n - 1) (List.tl l)

  let automaton_productions env =
    match top env with
    | None -> []
    | Some (Element (st, _, _, _)) -> items st |> List.map (fun (p, i) -> (lhs p, rhs p, p, i))

  let valid t =
    match match_error_token t with
    | None -> assert false
    | Some x ->
        let b, e = Error.span x in
        (t, b, e)

  let is_error_token x = match match_error_token x with None -> false | _ -> true
  let pp_element fmt elt = match elt with Element (st, x, _, _) -> pp_symbol (Some x) fmt @@ incoming_symbol st

  let pp_env fmt env =
    let rec to_list env =
      match top env with None -> [] | Some x -> x :: (match pop env with None -> [] | Some x -> to_list x)
    in
    let stack = List.rev @@ to_list env in
    Format.fprintf fmt "@[<hov 2>[@,%a]@]"
      (Format.pp_print_list ~pp_sep:(fun fmt () -> Format.fprintf fmt ";@ ") pp_element)
      stack

  let pp_gens fmt l = Format.fprintf fmt "%s" @@ (List.map (fun x -> x.s) l |> String.concat " ")
  let pp_xsymbol fmt = function X s -> pp_symbol None fmt s

  let pp_prod fmt x =
    Format.fprintf fmt "[%a <-- %a]" pp_xsymbol (lhs x)
      (Format.pp_print_list ~pp_sep:(fun fmt () -> Format.fprintf fmt "@ ") pp_xsymbol)
      (rhs x)

  let pp_prodn fmt (lhs, rhs, _, n) =
    Format.fprintf fmt "[%a <-- %a]@%d" pp_xsymbol lhs
      (Format.pp_print_list ~pp_sep:(fun fmt () -> Format.fprintf fmt "@ ") pp_xsymbol)
      rhs n

  let pp_prods fmt l = Format.pp_print_list ~pp_sep:(fun fmt () -> Format.fprintf fmt ";@ ") pp_prod fmt l
  let pp_prodsn fmt l = Format.pp_print_list ~pp_sep:(fun fmt () -> Format.fprintf fmt ";@ ") pp_prodn fmt l

  let merge_parse_error x y =
    match (match_error_token x, match_error_token y) with
    | Some x, Some y -> build_error_token (Error.merge x y)
    | _ -> assert false

  (* requires semantic actions to be pure *)
  let ensure_reduces : type a. a env -> production -> int -> production list =
   fun env prod pos ->
    try
      let _env : _ env = force_reduction prod env in
      [ prod ]
    with Invalid_argument _ -> []

  (* and next_symbols_opt = function None -> [] | Some env -> next_symbols env  *)
  let rec next_of (prod, pos) =
    match drop pos (rhs prod) with
    | [ X (T _); next ] when compare_symbols (lhs prod) next = 0 -> []
    | X (T x) :: _ -> token_of_terminal x |> o2l
    | X (N nt) :: _ when nullable nt -> next_of (prod, pos + 1)
    | _ -> []

  and o2l o = Option.fold ~none:[] ~some:(fun x -> [ x ]) o

  let automaton_possible_moves env b =
    match top env with
    | None -> ([], [])
    | Some (Element (st, _, _, _)) ->
        let items = items st in
        let reductions = List.concat_map (fun (p, i) -> ensure_reduces env p i) items in
        let tok (s, t) = { s; t; b; e = b } in
        let acceptable = List.concat_map next_of items |> List.map tok in
        (acceptable, reductions)


  (* a token waiting to be read: from the input, or made by the recovery *)
  type itok = { tok : token tok; input : bool }

  (* a simulation, see [lookahead.simulate] *)
  type sim = {
    limit : int; (* stop after [limit] tokens of the input are shifted *)
    script : (token, production) recovery_action list; (* the answers to the next errors *)
    lost_spans : (int * int) list; (* the text that went into errors *)
    sim_inserted : int; (* tokens and holes inserted *)
    budget : int; (* errors that may still be handled, against loops *)
  }

  type state = {
    tokens : token tok array; (* the whole input, lexed upfront, EOF last *)
    pos : int; (* the index in tokens of the next token to read *)
    errbuf : error list; (* all errors *)
    compbuf : completion list; (* all tokens inserted *)
    incoming_toks : itok list; (* the head of the token is the lookahead *)
    generation_streak : int; (* how many dummy tokens were generated since the last read from the stream *)
    ticks : int; (* when we reach eof we have at most ticks to terminate *)
    sim : sim option; (* when simulating a repair *)
    shifted : int; (* how many tokens of the input were shifted, in a simulation *)
  }

  exception Simulated of state * bool

  let in_sim st = st.sim <> None
  let dbg st f = if not (in_sim st) then dbg f

  (* the number of tokens of the input inside the spans *)
  let lost_tokens tokens spans =
    let spans = List.sort compare spans in
    let rec union = function
      | (b1, e1) :: (b2, e2) :: rest when b2 <= e1 -> union ((b1, max e1 e2) :: rest)
      | x :: rest -> x :: union rest
      | [] -> []
    in
    (* the first index whose token satisfies p, p being monotone *)
    let first p =
      let rec aux lo hi = if lo >= hi then lo else let m = (lo + hi) / 2 in if p tokens.(m) then aux lo m else aux (m + 1) hi in
      aux 0 (Array.length tokens)
    in
    List.fold_left
      (fun n (b, e) ->
        let i = first (fun t -> t.b.pos_cnum >= b) and j = first (fun t -> t.e.pos_cnum > e) in
        n + max 0 (j - i))
      0 (union spans)

  let add_lost st b e =
    match st.sim with
    | None -> st
    | Some sim -> { st with sim = Some { sim with lost_spans = (b.pos_cnum, e.pos_cnum) :: sim.lost_spans } }

  let add_inserted st =
    match st.sim with None -> st | Some sim -> { st with sim = Some { sim with sim_inserted = sim.sim_inserted + 1 } }

  let rec loop st (ckpt : ast checkpoint) =
    match ckpt with
    (* pretty much the definition of error resiliency *)
    | Rejected -> assert false
    (* standard part, we just log what happend for debugging. Shifting pops the tokens buffer *)
    | Accepted v ->
        if in_sim st then raise (Simulated (st, true));
        dbg st (fun () -> say "@[<hov 2>ACCEPT@]@\n");
        (st.errbuf, st.compbuf, v)
    | Shifting (_, s, _) ->
        dbg st (fun () -> say "@[<hov 2>SHIFT %a@]@\n" pp_env s);
        let shifted = match st.incoming_toks with { input = true } :: _ -> st.shifted + 1 | _ -> st.shifted in
        let st = { st with incoming_toks = tail st.incoming_toks; shifted } in
        (match st.sim with Some { limit } when shifted >= limit -> raise (Simulated (st, true)) | _ -> ());
        loop st (resume ckpt)
    | AboutToReduce (s, p) ->
        let n = List.length @@ rhs p in
        dbg st (fun () -> say "@[<hov 2>RED %d %a@]@\n" n pp_env s);
        let chkp = resume ckpt in
        loop st chkp
    (* reading: from the buffer if not empty, otherwise from the input *)
    | InputNeeded _env ->
        if st.ticks = 0 then
          if in_sim st then raise (Simulated (st, false))
          else invalid_arg "Mastic: too many loops. This should never happen, please report the issue"
        else
          let ((tok, _, _) as token), st =
            match st.incoming_toks with
            | { tok = t } :: _ -> (tok_to_triple t, st)
            | [] ->
                let n = Array.length st.tokens in
                let last_tok = st.tokens.(min st.pos (n - 1)) in
                let generation_streak, ticks =
                  if is_eof_token last_tok.t then (st.generation_streak, st.ticks - 1) else (0, st.ticks + 1)
                in
                ( tok_to_triple last_tok,
                  { st with incoming_toks = [ { tok = last_tok; input = true } ]; pos = st.pos + 1;
                            generation_streak; ticks } )
          in
          dbg st (fun () -> say "@[<hov 2>READ %s@]@\n" (show_token @@ tok));
          let chkp = offer ckpt token in
          loop st chkp
    (* handling errors, two cases:
       1. the lookahead does not fit (fail to shift)
       2. the stack does not reduce *)
    | HandlingError env -> (
        dbg st (fun () -> say "@[<hov 2>* ERROR: stack %a@]@\n" pp_env env);
        match st.incoming_toks with
        (* 1.1 shift failure, the token is invalid (not even a token, just a piece of text) *)
        | { tok = { s; t; b; e }; input } :: incoming_toks when is_error_token t ->
            dbg st (fun () -> say "@[<hov 2>  LOOKAHEAD: %s (invalid token)@]@\n" (show_token t));
            (* b and e are likely wrong after merge *)
            begin
              match ensure_top_is_error_token env with
              | None -> failwith "the grammar start symbol must include an atom for parse error"
              | Some (t0, env) ->
                  let t = merge_parse_error t0 t in
                  dbg st (fun () -> say "@[<hov 2>  RECOVERY: push (squashed) %s on %a@]@\n" (show_token t) pp_env env);
                  let ((_, vb, ve) as v) = valid t in
                  let chkp = offer (input_needed env) v in
                  let incoming_toks = { tok = { s; t; b; e }; input } :: incoming_toks in
                  loop (add_lost { st with incoming_toks } vb ve) chkp
            end
        (* 1.1 shift failure, the token does not fit *)
        | ({ tok = next_token } as next) :: incoming_toks -> begin
            let st, scripted =
              match st.sim with
              | Some ({ script = a :: script } as sim) -> ({ st with sim = Some { sim with script } }, Some a)
              | Some { budget } when budget <= 0 -> raise (Simulated (st, false))
              | Some sim -> ({ st with sim = Some { sim with budget = sim.budget - 1 } }, None)
              | None -> (st, None)
            in
            match scripted with
            | Some action -> apply_action st st env next incoming_toks action
            | None ->
                dbg st (fun () -> say "@[<hov 2>  LOOKAHEAD: %s (out of place token)@]@\n" (show_token next_token.t));
                let acceptable_tokens, reducible_productions = automaton_possible_moves env next_token.b in
                let productions = automaton_productions env in
                let state_id = current_state_number env in
                let st_w_err = { st with errbuf = ParseError (next_token.b, state_id) :: st.errbuf } in
                dbg st (fun () -> say "@[<hov 2>    STATE: %a@]@\n" pp_prodsn productions);
                dbg st (fun () -> say "@[<hov 2>    PROPOSE: reductions: %a@]@\n" pp_prods reducible_productions);
                dbg st (fun () -> say "@[<hov 2>    PROPOSE: tokens: %a@]@\n" pp_gens acceptable_tokens);
                let simulate ~limit actions =
                  if in_sim st then failed_simulation
                  else
                    let sim = { limit; script = actions; lost_spans = []; sim_inserted = 0; budget = 2 * limit + 10 } in
                    match loop { st with sim = Some sim; shifted = 0 } ckpt with
                    | _ -> assert false
                    | exception Simulated ({ sim = Some sim; shifted }, completed) ->
                        { shifted; completed; inserted = sim.sim_inserted; lost = lost_tokens st.tokens sim.lost_spans }
                    | exception ((Out_of_memory | Stack_overflow) as e) -> raise e
                    | exception _ -> failed_simulation
                in
                let lookahead =
                  { tokens = st.tokens; position = st.pos; pending = List.map (fun x -> x.tok) incoming_toks;
                    in_simulation = in_sim st; simulate }
                in
                let action =
                  handle_unexpected_token ~productions ~next_token ~reducible_productions ~acceptable_tokens
                    ~generation_streak:st.generation_streak ~lookahead
                in
                apply_action st_w_err st env next incoming_toks action
          end
        (* 2. reduce failure, we fold the stack into an error *)
        | [] -> assert false)

  (* st_w_err is st with the error recorded *)
  and apply_action st_w_err st env ({ tok = next_token } as next) incoming_toks action =
    match action with
    | (TurnIntoError | Skip) when is_eof_token next_token.t -> begin
        match ensure_top2_are_error_token env with
        | Empty | TopIsErr _ -> assert false
        | Top2AreErr (x, y, env) ->
            let t = merge_parse_error x y in
            (* TODO: fix locs *)
            let ((_, b, e) as valid) = valid t in
            dbg st (fun () -> say "@[<hov 2>  RECOVERY: squash %s and %s and push@]@\n" (show_token x) (show_token y));
            let chkp = offer (input_needed env) valid in
            let incoming_toks = { tok = { t; s = ""; b; e }; input = false } :: incoming_toks in
            loop (add_lost { st_w_err with incoming_toks } b e) chkp
      end
    | TurnIntoError ->
        let t =
          { next_token with t = build_error_token Error.(mkLexError (loc next_token.s next_token.b next_token.e)) }
        in
        let incoming_toks = { tok = t; input = false } :: incoming_toks in
        dbg st (fun () ->
            say "@[<hov 2>  RECOVERY: turn %s into %s and push@]@\n" (show_token next_token.t) (show_token t.t));
        let chkp = offer (input_needed env) (tok_to_triple t) in
        loop (add_lost { st_w_err with incoming_toks } t.b t.e) chkp
    | TurnIntoThisError e ->
        let t = { next_token with t = build_error_token e } in
        let incoming_toks = { tok = t; input = false } :: incoming_toks in
        dbg st (fun () ->
            say "@[<hov 2>  RECOVERY: turn %s into %s and push@]@\n" (show_token next_token.t) (show_token t.t));
        let chkp = offer (input_needed env) (tok_to_triple t) in
        loop (add_lost { st_w_err with incoming_toks } t.b t.e) chkp
    | Skip ->
        dbg st (fun () -> say "@[<hov 2>  RECOVERY: skip %s@]@\n" (show_token next_token.t));
        loop (add_lost { st_w_err with incoming_toks } next_token.b next_token.e) (input_needed env)
    | GenerateHole ->
        let b = next_token.b in
        let t = { s = "_"; t = build_error_token Error.(mkLexError (loc "_" b b)); b = next_token.b; e = next_token.b } in
        let incoming_toks = { tok = t; input = false } :: next :: incoming_toks in
        dbg st (fun () -> say "@[<hov 2>  RECOVERY: generate hole and push (generation_streak = %d)@]@\n" st.generation_streak);
        let chkp = offer (input_needed env) (tok_to_triple t) in
        let compbuf = (t.b, t.s) :: st.compbuf in
        let generation_streak = st.generation_streak + 1 in
        loop (add_inserted { st_w_err with incoming_toks; compbuf; generation_streak }) chkp
    | GenerateToken t ->
        let incoming_toks = { tok = t; input = false } :: next :: incoming_toks in
        dbg st (fun () ->
            say "@[<hov 2>  RECOVERY: generate %s and push (generation_streak = %d)@]@\n" t.s st.generation_streak);
        let chkp = offer (input_needed env) (tok_to_triple t) in
        let compbuf = (t.b, t.s) :: st.compbuf in
        let generation_streak = st.generation_streak + 1 in
        loop (add_inserted { st_w_err with incoming_toks; compbuf; generation_streak }) chkp
    | Reduce p ->
        let incoming_toks = next :: incoming_toks in
        dbg st (fun () -> say "@[<hov 2>  RECOVERY: reduce %a@]@\n" pp_prod p);
        let chkp = input_needed (force_reduction p env) in
        loop { st with incoming_toks } chkp
  (* all the tokens, up to EOF *)
  let lex lexbuf =
    let rec aux acc =
      let t = token lexbuf in
      let toks = Lexing.lexeme lexbuf in
      let s = if toks = "" then show_token t else toks in
      let tok = { s; t; b = lexbuf.lex_start_p; e = lexbuf.lex_curr_p } in
      if is_eof_token t then Array.of_list (List.rev (tok :: acc)) else aux (tok :: acc)
    in
    aux []

  let parse_tokens start tokens =
    if Array.length tokens = 0 || not (is_eof_token tokens.(Array.length tokens - 1).t) then
      invalid_arg "Mastic: the tokens must end with EOF";
    let chkp = main start in
    let st =
      { tokens; pos = 0; errbuf = []; compbuf = []; generation_streak = 0; incoming_toks = []; ticks = 1;
        sim = None; shifted = 0 }
    in
    loop st chkp

  let parse lexbuf =
    let start = lexbuf.lex_curr_p in
    parse_tokens start (lex lexbuf)
end

module Make
    (I : MenhirLib.IncrementalEngine.EVERYTHING)
    (M : IncrementalParser with type 'a checkpoint = 'a I.checkpoint and type token = I.token)
    (R :
      Recovery
        with type token = I.token
         and type 'a symbol = 'a I.symbol
         and type xsymbol = I.xsymbol
         and type 'a terminal = 'a I.terminal
         and type 'a env = 'a I.env
         and type production = I.production) =
struct
  include
    MakeLookahead (I) (M)
      (struct
        include R

        let handle_unexpected_token ~productions ~next_token ~acceptable_tokens ~reducible_productions
            ~generation_streak ~lookahead:_ =
          R.handle_unexpected_token ~productions ~next_token ~acceptable_tokens ~reducible_productions
            ~generation_streak
      end)
end
