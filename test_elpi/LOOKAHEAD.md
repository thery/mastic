# Recovery that looks ahead

This file explains in detail the second version of the recovery of the Elpi
parser: the input is lexed before parsing, and when an error is found, the
recovery sees all the tokens that follow and can *try* several repairs before
choosing one. It follows a reviewer's comment:

> separate lexing from parsing, so as to have all the tokens upfront. When an
> error is detected, pass these tokens to the error recovery function together
> with the current position. Can you improve error recovery with this extra
> data?

The work has two parts: a change in Mastic itself (sections 2 and 3), and
new rules in the recovery of Elpi that use it (section 4). Sections 5 to 7
give the experiments, the results and what to keep in mind.

- [1. Why looking ahead helps](#1-why-looking-ahead-helps)
- [2. Mastic: lexing upfront](#2-mastic-lexing-upfront)
- [3. Mastic: what the recovery sees, and trying a repair](#3-mastic-what-the-recovery-sees-and-trying-a-repair)
- [4. The new rules of the Elpi recovery](#4-the-new-rules-of-the-elpi-recovery)
- [5. What was tried, and rejected](#5-what-was-tried-and-rejected)
- [6. Results](#6-results)
- [7. Things to know](#7-things-to-know)
- [8. Where the code is](#8-where-the-code-is)

## 1. Why looking ahead helps

Until now, the recovery function decided on the spot, seeing only the token
that does not fit and the state of the parser. Some errors cannot be repaired
well that way. Take an extra parenthesis:

```prolog
p X :- q X), r.
```

When the parser meets `)`, it does not know whether a `(` is missing before
or the `)` is too much. The first strategy turned it into an error: the error
token does not fit after `q X`, so Mastic merged it with `q X`, and the
recovered clause was `p X :- Err«q X)», r`: the call `q X` was lost. Looking
at what follows (`, r.`) the answer is obvious: dropping the `)` lets the
parser go on to the end of the clause without any other error.

This is the idea of the classic *local repair* of Burke and Fisher: at an
error, try a few small repairs, run the parser a little further with each,
and keep the one that goes best. It needs two things the recovery did not
have: the tokens ahead, and a way to run the parser on a copy.

## 2. Mastic: lexing upfront

**Before.** Mastic's driver loop (`src/errorResilientParser.ml`) pulled the
tokens one at a time: when the parser needed a token, it called the lexer on
the `Lexing.lexbuf`, then read the text and positions of the token from the
`lexbuf`. A token was known only when the parser asked for it.

**Now.** The input is lexed first, entirely, into an array of tokens:

```ocaml
type 'token tok = { s : string; t : 'token; b : Lexing.position; e : Lexing.position }
(* the text, the token, its start and end *)

val lex : Lexing.lexbuf -> I.token tok array      (* up to EOF included *)
val parse_tokens : Lexing.position -> I.token tok array -> error list * completion list * M.ast
val parse : Lexing.lexbuf -> error list * completion list * M.ast   (* parse_tokens of lex *)
```

and the driver reads the array, keeping an index `position` (the first
token not read yet).

**The tokens are the same.** This works because the Elpi lexer does not
depend on the parser: it produces the same tokens whether they are read all at
once or one by one. That includes the delicate cases:

- the `% elpi:if version …` comments, which hide lines depending on the
  version;
- quotations `{{ … }}`;
- the error recovery of the lexer itself, which, on an unterminated string or
  comment, produces an error token for the opening `"` or `/*` and then goes
  back just after it;
- the second parse of a file with errors, with strings that cannot span
  lines (see the README): it lexes the text again, into a new array.

This was checked: on the 391 files of the corpus, `main.exe -raw` (every
error, inserted token and declaration of the error-resilient parser) and
`main.exe -strict` (the normal parser of Elpi) print exactly the same thing
before and after this change. The commit that only switched `test_elpi` to
the new functor changes no output at all.

## 3. Mastic: what the recovery sees, and trying a repair

### The new functor and the new argument

A new functor, `MakeLookahead`, takes a recovery whose
`handle_unexpected_token` has one more argument, `~lookahead`:

```ocaml
type ('token, 'production) lookahead = {
  tokens : 'token tok array;    (* all the tokens of the input, EOF last *)
  position : int;               (* the index of the first token not read yet *)
  pending : 'token tok list;    (* tokens read but not consumed, after next_token *)
  in_simulation : bool;         (* this call happens inside a simulation *)
  simulate : limit:int -> ('token, 'production) recovery_action list -> simulation;
}

val ahead : ('token, 'production) lookahead -> int -> 'token tok
(* ahead la k: the k-th token after next_token (k = 0: the next one), EOF past the end *)
```

- `tokens` and `position` are what the reviewer asked for: the whole input,
  and where the parser is in it.
- `pending` is needed because the recovery may have inserted tokens: when
  Mastic inserts `)` before the token `t` of the input, `next_token` is the
  inserted `)` and `t` is pending. `ahead` takes care of this: it gives the
  tokens that will really come next, pending ones first.
- `simulate` is explained below.

### Trying a repair: `simulate`

`simulate ~limit actions` answers the question "what happens if I do this?"
without changing the real parse:

1. Menhir's parser states (checkpoints) are immutable values, so the current
   one can be kept aside and the parser run from it on the side: this is a
   copy for free.
2. The parser goes on from the current error. The first errors it meets are
   answered by `actions`, in order (`[a]`: the current error is answered by
   `a`). The next errors are answered by the recovery itself, called with
   `in_simulation = true`. So a repair is judged *together with what the
   recovery will do afterwards*, not alone.
3. It stops when `limit` tokens of the input have been shifted (the horizon),
   or when the parse completes, or when it seems to loop (a budget of steps),
   or on an exception.
4. It returns what the repair cost on this horizon:

   ```ocaml
   type simulation = {
     shifted : int;       (* tokens of the input shifted *)
     lost : int;          (* tokens of the input that went into errors: merged
                             into an error, turned into errors, or skipped *)
     inserted : int;      (* tokens and holes inserted *)
     completed : bool;    (* the horizon was reached, or the parse completed *)
   }
   ```

Simulations do not nest: inside a simulation, `simulate` answers
`failed_simulation` at once. Otherwise each simulation would launch
simulations, and the cost would explode.

The semantic actions of the grammar run during a simulation, since it is
real parsing. They had better be pure. In the Elpi grammar the only side
effect that matters, the list of deferred errors (see the README, "Never
crash"), is saved before the simulations and restored after them.

### A new action: `Skip`

Besides `Reduce`, `GenerateToken`, `GenerateHole` and `TurnIntoError`, the
recovery can now answer `Skip`: the token is dropped, and an error is
recorded at its position. Before, the only way to get rid of a token was to
turn it into an error, and an error token must find a place in the tree,
which may merge it with what precedes, as with `q X)` above. The Elpi driver
reports skipped tokens: `error: line L, column C: skipped X`.

### Nothing changes for existing users

The old functor `Make` and the old `Recovery` signature are unchanged: `Make`
is now `MakeLookahead` with a recovery that ignores `~lookahead`. The toy
example of `test/` builds unchanged, and its cram tests print exactly what
they printed before.

## 4. The new rules of the Elpi recovery

The recovery of Elpi (`parser/parse.ml`, module `Recovery`) keeps the
strategy described in [STRATEGY.md](STRATEGY.md) (now the function
`default_strategy`) and adds five rules. Rules 1 to 4 are in
`handle_unexpected_token`, rule 5 is a pass on the array of tokens.

### Rule 1: search among the possible actions

At each error, instead of applying the default strategy directly:

1. **The candidates.** The action of the default strategy, and every other
   action that makes sense in this state: turn the token into an error, insert
   a hole, skip the token, insert each closer or `.` the parser accepts there,
   reduce each rule that can be reduced. Duplicates are removed.
2. **Each candidate is simulated** on the next 10 tokens of the input
   (`simulate ~limit:10 [a]`).
3. **Its cost** is computed from the simulation:

   ```ocaml
   let cost r =
     if r.shifted < 0 then max_int                      (* the simulation failed *)
     else (if r.completed then 0 else 1000)             (* it did not get through *)
          + 10 * r.lost + r.inserted                    (* a lost token weighs 10 insertions *)
   ```

   Losing a token of the input is much worse than inserting one: the user
   wrote that token, while an inserted one is a guess.
4. **The cheapest candidate wins, if it is clearly better than the
   default**: at least one token (a cost of 10) cheaper. Otherwise the default
   is kept. The margin avoids replacing the default for nothing, since the
   default was designed and measured case by case.

The search is not done inside a simulation (simulations do not nest), nor
after 10 insertions in a row. A first version without this guard looped on
26 edits of the corpus, alternating a hole and a reduction. A candidate whose
simulation did not get through never wins.

With `ELPI_LOOKAHEAD_DEBUG=1`, `main.exe` prints the choices. On the extra
parenthesis:

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

How to read the first line: at the token `)` (offset 15), turning it into
an error costs 30 (three tokens lost: the `)` is merged with `q X`), a hole 31
(the same, plus one insertion), skipping 10 (only the `)` is lost), reducing
rule 43 costs 70. Skipping wins, and the clause is recovered whole. Before,
it was `clause (:- (p X) (, Err«q X)» r))`.

In a long clause the difference is larger, since the error swallowed three
lines:

```
at 34 ")": error:100, hole:101, skip:10, reduce43:140 -> skip
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

Before: `clause (:- (p X) (, Err«q X,   r X,   s X X )» (t X) (u X)))`. The
measure of this case goes from F1 77.8 % to 96.9 %.

### Rule 2: bracket balance ahead

A closing bracket is not a candidate when the first closer *ahead* that has
no opening bracket after the error (looking only up to the `.` that ends the
declaration) is the same one (function `unmatched_closer_ahead`). In that
case the bracket gets closed later, and closing it now would leave an extra
closer there.

Why it matters: in Trocq's `param-arrow.elpi`, deleting the `[` of
`if (std.mem! [map2b, map3, map4] N) (…` made the search insert a `)` before
`N`. That was cheap on the next 10 tokens, but the real `)` then broke the
rest of the predicate: 437 nodes recovered out of 1 364, against 1 351 before
the search, and 1 351 again with this rule. The horizon of 10 tokens cannot
see such damage; the bracket count can.

### Rule 3: a dot is never skipped or turned into an error by the search

The default strategy may still do it, but the search does not propose it. A
`.` ends a declaration. Turning it into an error looks cheap on the next 10
tokens, but then the next declaration becomes part of the broken one, and the
damage only shows later, beyond the horizon.

### Rule 4: a token that ends its line, before a line starting at column 0

Such a token finishes the declaration, as a restart point does in the
default strategy (function `line_ends`), unless it asks for a continuation:
an opening bracket, `:-`, `,`, `;`, `|`, `\`, `->`, `:`. With the margin of
rule 1, this fixes the double dot:

```
at 8 "..": reduce251:11, error:10, hole:12, skip:10 -> reduce251
at 8 "..": insert .:11, error:20, hole:22, skip:11 -> insert .
at 8 "..": error:10, hole:11, skip:10 -> error
input: p 1.
       p 2..
       p 3.
error: line 2, column 3: completed with .
ast:
  clause (p 1)
  clause (p 2)
  error Err«..»
  clause (p 3)
```

Before: `clause (p 2 Err«..» p 3)`, with the next clause swallowed. Here the
search agrees with the default only thanks to the margin: turning `..` into an
error costs 10, about as much as reducing and inserting the `.` (11).

### Rule 5: brackets left open in the head of a clause are closed before `:-`

```prolog
p [X|Y :- q X.
```

Here the error is found too late for any rule at the error: `Y :- q X` is a
valid term, so the parser only complains at the final `.`, and by then the
whole clause is inside the open `[`. But a `.` is never inside `(` or `[` in a
valid program. So a pass on the array of tokens, before parsing (function
`close_brackets_in_head`), looks for declarations whose `(` or `[` are still
open at their `.`. If they were already open at the first `:-` of the
declaration, it closes them just before that `:-` (right after the previous
token), and reports the insertion:

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

Before: `error Err« p [X|Y :- q X.»`, recall 40 %, now 100 %. A valid program
never has a bracket open at a `.`, so this pass never changes one.

## 5. What was tried, and rejected

Each rule was kept only if it improved the measure on the whole corpus
(21 493 simulated edits, see the README). Every line below changes one thing
from the final strategy:

| variant | precision | recall | F1 |
|---|---:|---:|---:|
| before this work (STRATEGY.md, section 4) | 99.700 | 98.619 | 99.157 |
| only rules 4 and 5, no search (`ELPI_LOOKAHEAD=0`) | 99.704 | 98.664 | 99.181 |
| **final** | 99.684 | 99.100 | **99.391** |
| without the bracket balance (rule 2) | 99.684 | 99.083 | 99.383 |
| the search may skip or turn a dot into an error (no rule 3) | 99.680 | 99.078 | 99.378 |
| without the margin of one token, and without rule 4 | 99.685 | 99.096 | 99.390 |
| only punctuation may be skipped (not names, numbers…) | 99.684 | 99.059 | 99.371 |
| horizon of 5 tokens instead of 10 | 99.686 | 99.096 | 99.390 |
| horizon of 20 tokens | 99.685 | 99.097 | 99.390 |
| inserted closers placed just after the previous token | | | same (one node more) |

What this says:

- **The search does most of the work**: 99.18 without it, 99.39 with it.
- **Rules 2 and 3 are small on average** but avoid rare large losses (the
  Trocq example above).
- **The horizon hardly matters** beyond 5 tokens.
- **Skipping only punctuation** would avoid one regression in `fuzz.t` (see
  section 7) but loses more elsewhere.

## 6. Results

On the corpus (387 files, 21 493 edits), `improved.txt`:

| edit | F1 before | F1 now |
|---|---:|---:|
| truncate (the file cut, as while typing) | 98.89 % | 99.35 % |
| del-token | 99.36 % | 99.51 % |
| del-line | 99.34 % | 99.52 % |
| del-chunk | 99.15 % | 99.36 % |
| del-closer (a `)` `]` `}` `.` deleted) | 98.63 % | 99.05 % |
| half-token | 99.44 % | 99.54 % |
| **total** | **99.16 %** | **99.39 %** |

Precision 99.70 % → 99.68 %, recall 98.62 % → 99.10 %. Characters inside
errors, per edit: 28.5 → 14.4. Errors covering a whole declaration, per
edit: 0.06 → 0.05. Still no crash and no timeout.

Recall is what improves: errors are smaller (half the characters), so less of
the good tree is lost. Precision moves a little the other way: a skipped
token is a bolder guess than an error node.

The cases of `cases.t` that changed, each against its good version:

| case | before | now |
|---|---:|---:|
| 04, extra `)` | F1 91.9 % | 100 % |
| 05, missing `]` before `:-` | F1 57.1 % | 100 % |
| 10, double `.` | F1 72.7 % | 100 % |
| 29, extra `)` in a long clause | F1 77.8 % | 96.9 % |

No other case changed.

**Cost.** The simulation of the corpus takes about 4 minutes on 14 cores. A
valid program pays nothing: without errors there is no simulation.

## 7. Things to know

- **A regression in `fuzz.t`.** In `p :- X is 2 + 3   4.` (the `*` replaced
  by spaces), the search skips the `4`:

  ```
  at 18 "4": error:20, hole:21, skip:10, reduce262:40 -> skip
  ast:   clause (:- p (is X (+ 2 3)))
  ```

  Before, the error was `+ 2 Err«3   4»`, closer in shape to the good
  `+ 2 (* 3 4)`: F1 went from 87 % to 58 % on this input. Both are guesses;
  the measure prefers the error node, which keeps the span. Allowing only
  punctuation to be skipped avoids this, but costs more on the corpus.
- **The missing `.` before a line that can continue the clause** is still
  not repaired (cases 08 and 09). `p 2` then `p 3.` is the valid clause
  `p 2 p 3`; splitting it would change how valid programs parse. Likewise
  `p # 2.` (`#` is an infix operator in Elpi). The unterminated string (case
  16) is a matter for the lexer.
- **Side effects during simulations.** The semantic actions run in
  simulations. The deferred errors are saved and restored. Two other mutable
  things of the parser are not: the counter of fresh variable names and the
  cache of accumulated files. They do not change any output on the corpus,
  but a grammar with more side effects would need care.
- **Skipped tokens** are reported in the list of errors (`skipped X`), but
  not underlined in the printed source, since they are not nodes of the tree.
- **Switches.** `ELPI_LOOKAHEAD` sets the horizon (10 by default; 0 turns the
  search off). `ELPI_LOOKAHEAD_DEBUG=1` prints each choice. The choices are
  printed twice for a file with errors, because of its second parse with
  single-line strings.

## 8. Where the code is

| what | where |
|---|---|
| lexing upfront, `MakeLookahead`, `lookahead`, `simulate`, `Skip` | `src/errorResilientParser.ml(i)` |
| the default strategy (STRATEGY.md) | `default_strategy` in `parser/parse.ml` |
| rule 1, the search, and its cost | `handle_unexpected_token`, `cost`, `margin` in `parser/parse.ml` |
| rule 2 | `unmatched_closer_ahead` |
| rule 4 | `line_ends` |
| rule 5 | `close_brackets_in_head` |
| skipped tokens in the error list | `skipped`, `skipped_message`, and `main.ml` |

Commits, on branch `test-elpi`:

- `33d313c` Mastic: lex the input upfront, `MakeLookahead` gives the recovery the tokens ahead
- `3f28dfe` test_elpi: use `MakeLookahead` (same results: the tokens are now lexed upfront)
- `63873dd` Mastic: `Skip` action; simulations continue with the recovery and report what they cost
- `433e512` test_elpi: a recovery that looks ahead
- `d0454c1` test_elpi: document the lexing upfront and the lookahead; `improved.txt` regenerated
