# The recovery strategy, compared with the PR on Elpi

The first version of this work is the draft PR
[LPCIC/elpi#385](https://github.com/LPCIC/elpi/pull/385) (branch
`error-parser` of Elpi). This file explains what changed in the recovery
since then: first the function that chooses what to do on an unexpected token,
`Recovery.handle_unexpected_token`, then the other functions of the module
`Recovery`, then what changed around it; section 5 is the recovery that looks
ahead, with all the tokens lexed upfront. All of it is in
[`parser/parse.ml`](parser/parse.ml), except where said otherwise.

## Reminder: what Mastic asks

When a token does not fit, Mastic calls `handle_unexpected_token` with the
state of the parser (its items, the tokens it would accept, the rules it could
reduce, the number of tokens inserted since the last one read), and the
function answers with one action:

| action | what Mastic does |
|---|---|
| `Reduce p` | completes the rule `p` |
| `GenerateToken t` | inserts the token `t` before the unexpected one |
| `GenerateHole` | inserts an empty error token, an error where something is missing |
| `TurnIntoError` | turns the unexpected token into an error token |

An error token that does not fit is merged with the top of the parser stack,
again and again, until a grammar rule accepts it.

## 1. The function `handle_unexpected_token`

### In the PR

```ocaml
let handle_unexpected_token ~productions ~next_token ~acceptable_tokens
    ~reducible_productions ~generation_streak =
  let open Mastic.ErrorResilientParser in
  match reducible_productions with
  | p :: _ when List.exists is_term productions -> Reduce p
  | _ ->
     match next_token.t with
     | Tokens.FULLSTOP -> complete ()        (* complete () = TurnIntoError *)
     | _ -> TurnIntoError
```

Inside a term, reduce; otherwise turn the token into an error. Since only
`decl` accepts an error token in the grammar of the PR, Mastic merges the
whole declaration into the error:

```
input: p :- X is + 2 * 3.
ast:   error Err«p :- X is +»     error Err«2»     error Err«*»     error Err«3»     error Err«.»
```

(five declaration errors: the clause is lost).

### Now

```ocaml
let handle_unexpected_token ~productions ~next_token ~acceptable_tokens
    ~reducible_productions ~generation_streak =
  let open Mastic.ErrorResilientParser in
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
        else GenerateToken (* DECL_ERROR_TOKEN *) ... in
  if generation_streak >= 10 || List.exists is_decl_start productions then TurnIntoError
  else if reducible_productions = [] && generation_streak = 0 && expects_term_or_type productions then
    GenerateHole
  else match next_token.t with
  | Tokens.FULLSTOP | Tokens.EOF -> finish ()
  | t when restart_point t next_token.b -> finish ()
  | _ ->
  match reducible_productions with
  | p :: _ when List.exists is_term productions -> Reduce p
  | _ -> TurnIntoError
```

The rules, in the order they are tried:

**1. Give up** (`TurnIntoError`) when 10 tokens have been inserted in a row
(new: it prevents loops), or at the beginning of a declaration (as in the
PR, where it was the only possibility). The beginning of a declaration is
recognised by its items: `decl -> . …`, or `program -> decl . program` right
after a declaration (Menhir only lists the kernel items of a state, so the
first one is rarely seen).

**2. A term or a type is missing: insert a hole** (new). When no rule can
be reduced, nothing has been inserted yet, and the state waits for a term or
a type:

```ocaml
let expects_term_or_type productions =
  let next (_, rhs, _, pos) = List.nth_opt rhs pos in
  List.for_all (fun i -> next i <> None) productions &&      (* no item is complete *)
  List.exists (fun i -> match next i with                    (* one expects a term or a type *)
    | Some (X (N (N_term | N_term_noconj | N_closed_term | N_head_term
                 | N_type_term | N_atype_term | N_fotype_term | N_kind_term))) -> true
    | _ -> false) productions
```

The hole is an empty error token, which the error rules of terms and types
accept (see below):

```
input: p :- X is + 2 * 3.               input: pred q i:.
ast:   clause (:- p (is X (+ Err«» (* 2 3))))      pred q (pred i:Err«»)
```

**3. At a `.`, at the end of the file or at a restart point: finish the
declaration** (new). A restart point is a token that probably begins the next
declaration: a token at the beginning of a line, or a keyword that only begins
declarations (`pred`, `func`, `type`, `kind`, `namespace`, `typeabbrev`,
`accumulate`, `shorten`, `macro`, `constraint`, `rule`). The function
`finish` tries, in order:

1. reduce, with any rule (in the PR, only inside a term);
2. insert the `.`, or a closing `)` `]` `}`, when the parser accepts it
   (`acceptable_tokens`, empty in the PR, see `token_of_terminal`):
   ```
   input: p X :- q (X, r.
   error: line 1, column 14: completed with )
   ast:   clause (:- (p X) (q (, X r)))
   ```
3. insert a `.` anyway: Menhir may accept it after reducing empty rules,
   which Mastic does not list in `reducible_productions`;
4. insert a hole once, in case a term is missing before the `.`;
5. insert a `DECL_ERROR_TOKEN`: an error token that only `decl` accepts, so
   Mastic merges the stack into it up to the declaration, which becomes an
   error, and parsing starts again at the restart point.

So an unfinished declaration no longer swallows the following ones (in the
PR, the next keyword was turned into an error and merged into it).

**4. Otherwise: as in the PR.** Reduce inside a term, else turn the token
into an error. With the error rules of terms, the error now stays inside the
term instead of taking the whole declaration:

```
input: p X :- q X), r.
ast:   clause (:- (p X) (, Err«q X)» r))
```

## 2. The other functions of `Recovery`

**`token_of_terminal`**, the tokens the recovery may insert. In the PR it
always answers `None`, so `acceptable_tokens` is always empty and no token is
ever inserted. Now:

```ocaml
let token_of_terminal : type a. a terminal -> (string * token) option = function
  | T_RPAREN -> Some (")", Tokens.RPAREN)
  | T_RBRACKET -> Some ("]", Tokens.RBRACKET)
  | T_RCURLY -> Some ("}", Tokens.RCURLY)
  | T_FULLSTOP -> Some (".", Tokens.FULLSTOP)
  | _ -> None
```

**`reduce_as_parse_error`**, what an item of the parser stack becomes when
Mastic merges it into an error. In the PR, a declaration kept its value and
everything else became `('TODO', start, end)`: the content was lost. Now every
item keeps it: terms (`term`, `closed_term`, `head_term`, …, the clause head)
become pieces of a term error, types pieces of a type error, attributes
pieces of an attribute error, lists their elements one by one, names and
strings their text.

**`match_error_token` / `build_error_token`** also recognise and rebuild
`DECL_ERROR_TOKEN`. When Mastic merges errors it rebuilds the token from the
merged `Mastic.Error.t`, so a `DECL_ERROR_TOKEN` is marked by a piece
`Lex "\000"`, which survives the merges.

## 3. Around the strategy

These changes are not in `Recovery`, but the strategy relies on them.

| | the PR | now |
|---|---|---|
| error nodes (`ast.ml`) | declarations | declarations, terms (`Term.Err`), types (`TErr`), attributes (`AttributeError`) |
| error rules (`grammar.mly`) | `decl` | `decl` (and `DECL_ERROR_TOKEN`), `closed_term`, the clause head, `atype_term`, `fotype_term`, `kind_term`, `attribute` |
| lexer (`lexer.mll.in`) | raises on `$`, unterminated strings, quotations, comments | returns an error token (for an unterminated string, the opening `"`, and lexing starts again after it), and records the error |
| semantic actions (`grammar.mly`, `ast.ml`) | raise on ill-formed programs | defer the error and return an error node (`Ast.Term.defer`) |
| strings missing their closing `"` | run to the next `"` | when the file has errors, a second parse with strings on one line; the result with more correct declarations is kept |
| errors reported | as Mastic returns them | consecutive declaration errors merged, one error per position |
| normal parsing path of Elpi | goes through Mastic | unchanged: the error-resilient parser is a separate entry point, `Parse.Internal.program_resilient` |

## 4. The effect

On the corpus (387 files, 21 493 simulated edits, see the
[README](README.md#9-results)), with the same grammar and error nodes, only
the strategy and the points of section 3 differing (the last column adds the
lookahead of section 5):

| | strategy of the PR | sections 1–3 | with lookahead |
|---|---:|---:|---:|
| crashes | 680 | 0 | 0 |
| recall | 90.4 % | 98.6 % | 99.1 % |
| precision | 99.7 % | 99.7 % | 99.7 % |
| F1 | 94.8 % | 99.2 % | 99.4 % |

## 5. Lexing upfront and looking ahead

A reviewer suggested: *separate lexing from parsing, so as to have all the
tokens upfront; when an error is detected, pass these tokens to the recovery
together with the current position.* This section explains how it is done
and which rules use it.

### Mastic: all the tokens, and a way to try a repair

Mastic used to pull the tokens one by one from a `Lexing.lexbuf`. Now
(`src/errorResilientParser.ml`) the input is lexed first into an array of
tokens (`{ s; t; b; e }`, `EOF` last), and the parser reads that array. The
Elpi lexer does not depend on the parser, so the tokens are the same as
before, including the `% elpi:if version` comments, the quotations, the
rewind on an unterminated string or comment, and the second parse with
single-line strings (which lexes the text again): on the 391 files of the
corpus, `main.exe -raw` and `main.exe -strict` print exactly the same thing
as before.

A new functor, `MakeLookahead`, takes a recovery whose
`handle_unexpected_token` also receives `~lookahead`:

```ocaml
type ('token, 'production) lookahead = {
  tokens : 'token tok array;   (* all the tokens of the input *)
  position : int;              (* the index of the first token not read yet *)
  pending : 'token tok list;   (* tokens read but not consumed after next_token *)
  in_simulation : bool;
  simulate : limit:int -> ('token, 'production) recovery_action list -> simulation;
}
type simulation = { shifted : int; lost : int; inserted : int; completed : bool }
```

`simulate ~limit actions` tries a repair without touching the real parse
(Menhir's checkpoints are immutable, so this is just running the loop on a
copy): the first errors are answered by `actions`, the next ones by the
recovery itself (with `in_simulation = true`, so that simulations do not
nest), until `limit` tokens of the input have been shifted. It returns what
the repair costs over this horizon: the tokens of the input that went into
errors (merged into the stack, turned into errors, or skipped), and the
tokens inserted. This is Burke–Fisher's local repair, with the rest of the
recovery as the continuation. The semantic actions run during simulations;
the only side effect in the Elpi grammar, the list of deferred errors, is
saved and restored around them.

Mastic also has a new action, `Skip`: the token is dropped, and the error is
recorded at its position (the Elpi driver reports it as `skipped X`). The old
functor `Make` and the old `Recovery` signature are unchanged (`Make` is
`MakeLookahead` with a recovery that ignores the lookahead): the tests of
`test/` print the same as before.

### The rules that use the tokens ahead

**1. Search among the possible actions.** At each error, the recovery
computes the action of the strategy of section 1 (the *default*), and the
other actions that make sense in the state: turn the token into an error,
insert a hole, skip the token, insert each closer or `.` the parser accepts,
reduce each rule that can be reduced. Each one is simulated on the next 10
tokens; its cost is 10 per token of the input lost in an error plus 1 per
token inserted. The cheapest wins, but the default is kept unless another
action saves at least a whole token. The search is off inside a simulation,
and after 10 insertions in a row (the first version of the search, without
this guard, looped on 26 edits of the corpus, alternating a hole and a
reduction). With `ELPI_LOOKAHEAD_DEBUG=1`, `main.exe` prints the choices
(twice: the text is parsed a second time with single-line strings):

```
at 15 ")": error:30, hole:31, skip:10, reduce43:70 -> skip
input: p 1.
       p X :- q X), r.
       p 3.
error: line 2, column 10: skipped )
ast:
  clause (p 1)
  clause (:- (p X) (, (q X) r))
  clause (p 3)
```

Before, the `)` was turned into an error and merged with `q X`
(`Err«q X)»`); in a long clause the merge took three lines:

```
input: p X :-
         q X,
         r X,
         s X X ),
         t X,
         u X.
error: line 5, column 8: skipped )
ast:
  clause (:- (p X) (, (q X) (r X) (s X X) (t X) (u X)))
```

(before: `clause (:- (p X) (, Err«q X,   r X,   s X X )» (t X) (u X)))`,
recall 66 %, now 97 %).

**2. Bracket balance ahead.** A closer is not a candidate when the first
closer of the declaration that is not matched ahead (a dot outside brackets
ends the declaration) is the same one: the bracket is closed later, closing
it now would leave an extra closer there. Without this rule, in Trocq's
`param-arrow.elpi` with the `[` of `if (std.mem! [map2b, map3, map4] N) (`
deleted, the search inserted a `)` before `N` (cheap on the next 10 tokens),
and the real `)` then broke the rest of the predicate: 437 nodes recovered
out of 1 364, against 1 351 before the search, and 1 351 again with the rule.

**3. A dot is not turned into an error or skipped by the search** (the
default strategy may still do it). Turning a `.` into an error looks cheap
on the next 10 tokens, but the next declaration then becomes part of the
broken one, and the damage shows only later.

**4. A token that ends its line, before a line starting at column 0,
finishes the declaration** (in the default strategy, as a restart point does),
unless the token asks for a continuation (an opening bracket, `:-`, `,`,
`;`, `|`, `\`, `->`, `:`):

```
at 8 "..": reduce251:11, error:10, hole:12, skip:10 -> reduce251
at 8 "..": insert .:11, error:20, hole:22, skip:11 -> insert .
at 8 "..": error:10, hole:11, skip:10 -> error
input: p 1.
       p 2..
error:    ^^ recovered syntax error
       p 3.
error: line 2, column 3: completed with .
ast:
  clause (p 1)
  clause (p 2)
  error Err«..»
  clause (p 3)
```

(before: `clause (p 2 Err«..» p 3)`). Here the search agrees with the
default only thanks to the margin of one token: turning `..` into an error
costs 10, as much as reducing and inserting the `.` (11).

**5. Brackets left open in the head of a clause** are closed before its
`:-`. This one is a pass on the array of tokens before parsing (function
`close_brackets_in_head`), as the error is detected too late: in
`p [X|Y :- q X.`, `Y :- q X` is a valid term, and the parser only complains
at the `.`. A `.` is never inside `(` or `[` in a valid program, so a
declaration whose `(` or `[` are still open at its `.` is wrong; if they were
already open at its first `:-`, they are closed just before it (just after
the previous token):

```
input: p 1.
       p [X|Y :- q X.
       p 3.
error: line 2, column 6: completed with ]
ast:
  clause (p 1)
  clause (:- (p (:: X Y)) (q X))
  clause (p 3)
```

(before: `error Err« p [X|Y :- q X.»`, recall 40 %, now 100 %).

### Tried and rejected

On the whole corpus (21 493 edits), F1 with three decimals, each line
changing one thing from the final strategy (or from the version measured
then):

| variant | precision | recall | F1 |
|---|---:|---:|---:|
| before (section 4) | 99.700 | 98.619 | 99.157 |
| only rules 4 and 5, no search (`ELPI_LOOKAHEAD=0`) | 99.704 | 98.664 | 99.181 |
| **final** | 99.684 | 99.100 | **99.391** |
| without the bracket balance (rule 2) | 99.684 | 99.083 | 99.383 |
| the search may skip or turn a dot into an error (no rule 3) | 99.680 | 99.078 | 99.378 |
| without the margin of one token and rule 4 | 99.685 | 99.096 | 99.390 |
| only punctuation may be skipped (not names, numbers, …) | 99.684 | 99.059 | 99.371 (*) |
| horizon of 5 tokens instead of 10 | 99.686 | 99.096 | 99.390 |
| horizon of 20 tokens | 99.685 | 99.097 | 99.390 |
| inserted closers placed just after the previous token | | | same (one node more) |

(*) with 2 timeouts, which did not reproduce when run alone.

Rules 2 and 3 are small on average but avoid the large losses described
above. Skipping only punctuation would avoid a regression of `fuzz.t`
(`p :- X is 2 + 3   4.`: the `4` is skipped, and `+ 2 3` no longer has the
span of `+ 2 Err«3 4»`), but it loses more elsewhere. The horizon matters
little beyond 5 tokens. The position of inserted closers changed one node.

Some cases cannot be helped without changing how valid programs parse: a
missing `.` before a line that can continue the clause (`p 2` then `p 3.`
is the valid clause `p 2 p 3`; `p X :- q X` then `p 3 :- r.` is valid too),
or `p # 2.` (`#` is an infix operator). An unterminated string
(`p "abc.`) is a lexing matter.

### The effect

| edit | before F1 | now F1 |
|---|---:|---:|
| truncate | 98.89 % | 99.35 % |
| del-token | 99.36 % | 99.51 % |
| del-line | 99.34 % | 99.52 % |
| del-chunk | 99.15 % | 99.36 % |
| del-closer | 98.63 % | 99.05 % |
| half-token | 99.44 % | 99.54 % |
| **total** | **99.16 %** | **99.39 %** |

Precision 99.70 % → 99.68 %, recall 98.62 % → 99.10 %, characters inside
errors per edit 28.5 → 14.4, still no crash nor timeout. The simulation of
the corpus takes about 4 minutes on 14 cores; a valid program does not pay
anything (no error, no simulation).
