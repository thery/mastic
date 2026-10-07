# The recovery strategy, compared with the PR on Elpi

The first version of this work is the draft PR
[LPCIC/elpi#385](https://github.com/LPCIC/elpi/pull/385) (branch
`error-parser` of Elpi). This file explains what changed in the recovery
since then: first the function that chooses what to do on an unexpected token,
`Recovery.handle_unexpected_token`, then the other functions of the module
`Recovery`, then what changed around it. All of it is in
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
the strategy and the points of section 3 differing:

| | strategy of the PR | now |
|---|---:|---:|
| crashes | 680 | 0 |
| recall | 90.4 % | 98.6 % |
| precision | 99.7 % | 99.7 % |
| F1 | 94.8 % | 99.2 % |
