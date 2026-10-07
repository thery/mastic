# Mastic on the Elpi grammar

`test/` shows Mastic on a toy language; this directory does the same on a
real one, the grammar of [Elpi](https://github.com/LPCIC/elpi), following the
steps of the [README](../README.md):

1. **every AST type has an error node**: declarations (`Program.Error`),
   terms (`Term.Err`), type expressions (`TypeExpression.TErr`) and
   attributes (`AttributeError`);
2. **every grammar rule producing one has an error rule**
   (`closed_term: | e = ERROR_TOKEN { Term.of_token e }`, and the same for
   `decl`, the clause head, `atype_term`, `fotype_term`, `kind_term`,
   `attribute`); when Mastic folds the stack into an error, the items keep
   their content (`reduce_as_parse_error`: subterms, types, names);
3. **a recovery strategy** (`Recovery.handle_unexpected_token` in
   `parser/parse.ml`).

`util/` and `parser/` are copies of `src/utils` and `src/parser` of the
branch [`mastic-systematic`](https://github.com/thery/elpi/tree/mastic-systematic)
of Elpi (current master plus these changes; there the normal parsing path of
Elpi is unchanged). Only parsing is tested here: `accumulate` of a file that
cannot be found reads an empty file.

## The tool: `main.exe`, as `test/main.exe`

```
$ echo 'p :- X is + 2 * 3.' | dune exec test_elpi/main.exe
input: p :- X is + 2 * 3.
error:           ^        recovered syntax error
error: line 1, column 10: completed with _
ast:
  clause (:- p (is X (+ Err«» (* 2 3))))
```

The input, the error nodes underlined, the tokens inserted by the recovery,
and the AST: terms as s-expressions, error nodes as `Err«source text»`. Here
the left operand of `+` is missing: an error node takes its place, and
`Err + 2 * 3` is a proper tree.

`-fuzz N -rands …` fuzzes the input as in `test/` (a character replaced by
`;`, space or `$`), and prints `note: not a subterm` when the AST of the
fuzzed input is not included in the original one (an error node is included
in anything).

## The measure

How much does the AST A2 recovered from a damaged program look like the AST
A1 of the good program it comes from? (`measure` in `main.ml`)

- An AST is the set of its nodes, each written (label, start, end): its kind
  and name (`clause`, `app:is`, `const:X`, `data:2`, `tconst:int`, `pred:q`,
  …) and its span in the source. Error nodes are not counted: they stand
  for "unknown".
- The two programs differ in one region (their longest common prefix and
  suffix delimit it). Positions before it stay, positions after it are
  shifted, positions inside it are unknown and match any position of the
  region in the other program; so the clause around a damaged term is still
  expected. Nodes lying entirely in the region (removed or added text) are not
  counted.
- **recall** = matched / nodes of A1: how much of the good tree is recovered
  (an error node loses the nodes it replaces);
  **precision** = matched / nodes of A2: how much of the recovered tree is
  right (two clauses merged, or the end of a clause read as a new clause,
  lower it; an error node does not); **F1** = their harmonic mean.

This is the PARSEVAL measure used to evaluate natural language parsers.
`main.exe -ref GOOD FILE` prints it for FILE against GOOD, and `-fuzz` for
each fuzzed input against the original.

## The tests

- `cases.t`: 32 small programs with one kind of syntax error each
  (`cases/*.elpi`), each compared with the good program it comes from
  (`cases/*.ref`): missing operands, unbalanced brackets, missing or double
  `.`, unknown characters, unterminated strings and comments, broken `pred`,
  `type`, `kind`, `namespace`, end of file in a clause, …
- `fuzz.t`: fuzzing, as in `test/`, with the measure of each fuzzed input.

Both are cram tests: `dune runtest test_elpi`, and `dune promote` to accept
a change.

## The editing simulation: `recov.py fuzz`

```
python3 test_elpi/recov.py fuzz test_elpi/corpus/*/*.elpi
```

damages valid programs as someone typing does (the file cut at a token, a
token, a line or a few lines deleted, a closing `)` `]` `}` `.` deleted, a
token cut in the middle), 10 edits of each kind per file, and reports the
measure, summed over the edits (a crash recovers nothing), and the error
nodes: whole declarations (`decl-errs`) or smaller (`term-errs`), and their
size (`err-chars`), per edit.

On the whole corpus (387 files, 21 493 edits), `improved.txt`:

|               | strategy of error-parser | this strategy |
|---------------|-------------------------:|--------------:|
| crashes       | 680                      | **0**         |
| precision     | 99.7 %                   | 99.7 %        |
| recall        | 90.4 %                   | **98.6 %**    |
| F1            | 94.8 %                   | **99.2 %**    |
| whole-declaration errors per edit | 0.27 | **0.06**      |
| characters in errors per edit     | 137  | **28**        |

`baseline.txt` is the recovery strategy of the error-parser branch
(LPCIC/elpi#385: reduce inside a term, otherwise turn the token into an
error; the lexer and the semantic actions raise), with the same grammar and
error nodes. Precision is the same: both rarely build a wrong structure; the
difference is how much of the good structure survives.

The corpus (`corpus/`, each project with its license): the programs of
Elpi's `tests/sources`, and the Elpi files of hierarchy-builder, Trocq,
Trakt, coq-elpi, math-comp, one_num_type and elpiDiff.
