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

## The tests

- `cases.t`: 32 small programs with one kind of syntax error each
  (`cases/*.elpi`): missing operands, unbalanced brackets, missing or double
  `.`, unknown characters, unterminated strings and comments, broken `pred`,
  `type`, `kind`, `namespace`, end of file in a clause, …
- `fuzz.t`: fuzzing, as in `test/`.

Both are cram tests: `dune runtest test_elpi`, and `dune promote` to accept
a change.

## The editing simulation: `recov.py fuzz`

```
python3 test_elpi/recov.py fuzz test_elpi/corpus/*/*.elpi
```

damages valid programs as someone typing does (the file cut at a token, a
token, a line or a few lines deleted, a closing `)` `]` `}` `.` deleted, a
token cut in the middle), 10 edits of each kind per file, and checks what is
recovered. Each declaration of the original owns its text up to the next
one; the declarations the edit does not touch should come back unchanged.

| column | meaning |
|---|---|
| `crash` | the parser did not return |
| `decl-errs` | error nodes covering a whole declaration, per edit |
| `term-errs` | smaller error nodes (term, type, attribute), per edit |
| `err-chars` | characters inside error nodes, per edit |
| `parsed%` | part of the file outside error nodes (a crash counts 0 %) |
| `lost` | untouched declarations not recovered (`far`: not next to the edit) |

The corpus (`corpus/`, each project with its license): the programs of
Elpi's `tests/sources`, and the Elpi files of hierarchy-builder, Trocq,
Trakt, coq-elpi, math-comp, one_num_type and elpiDiff.
