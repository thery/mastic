# Jasmin

The `.jazz` files of https://github.com/jasmin-lang/jasmin (commit
dc28494, directories `compiler/tests`, `compiler/examples`,
`compiler/CCT`, …) that parse with the parser of Jasmin, copied unchanged
with their directory structure (1015 of the 1017 files: the two left out,
`tests/fail/common/var_initialize_if.jazz` and `tests/fail/x86-64/string.jazz`,
are tests of syntax errors). License: MIT, see `LICENSE`.

Used as a test set for error recovery: `recov.py fuzz` damages them and
checks what is recovered. Only parsing is tested: a `require` is not
followed, so the files it names need not be there.
