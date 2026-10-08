# Mastic

Mastic is a library that makes Menhir-based parsers error-resilient.

## What is error resilience?

A parser is error-resilient if:
- It never fails to produce a semantic value.
- It never discards any token.

Compilers typically stop at the first syntax error, so standard parsing
technologies like Menhir don't prioritize resilience. In contrast,
language servers used by IDEs almost never receive an error-free
document, yet they still need to process it. If the standard parser just
fails, they can't use it. Writing and maintaining a separate, error-resilient
parser is unsatisfactory because it must be kept in sync with the main one.

To ensure a result is always produced, the syntax tree must include at least
one (top-level) node that can carry errors; therefore this node cannot be `None`.
A parser that always returns the node `Error [all the tokens]` is technically
resilient, although not very useful. Keeping all tokens is important because they
correspond to text elements the IDE manipulates, from syntax highlighting
to completion to jump-to-definition.

## What does Mastic do for me?

With minimal changes to your grammar and syntax tree, Mastic
gives you an error-resilient parser.

For the syntax tree, you add at least one `Error` node.
More fine-grained error nodes are even better. The additions follow a
predictable pattern that a ppx could generate.

For the grammar, you append the same production at the end of each block of
rules that produces the `Error` node. Again, this is systematic and a Menhir
ppx could generate it.

In addition, you can provide a grammar-specific error handler to improve recovery,
that is, to generate `Error` nodes for the smallest possible span of text.
For example, it can identify good synchronization points for restarting the
parser, such as tokens that begin top-level grammar entries.

## How should I change my grammar?

First, you need these two tokens (the first one you may have it already)

```
%token EOF
%token <Mastic.Error.t> ERROR_TOKEN
```

The lexer should  end with something like:

```
| eof { EOF }
| _ as x { ERROR_TOKEN Mastic.Error.(mkLexError (loc (String.make 1 x) lexbuf.lex_start_p lexbuf.lex_curr_p)) }
```

The grammar should have an error case per non termianl (we assume the nonterminal `expr` has type `Expr.t`):

```
expr:
| ...
| e = ERROR_TOKEN;  { Expr.of_token e }
```

And the ast should have the following boilerplate:

```ocaml
module Expr = struct
  type t =
    | ...
    | Err of Error.t
    [@@deriving show]

  type Error.t_ += Expr of t
  let (Error.Registered { of_token; build_token; is_err }) =
    Error.register "Expr.t"
      { pp;
        match_ast = (function Err x -> Some x | _ -> None);
        build_ast = (fun x -> Err x);
        match_error = (function Expr x -> Some x | _ -> None);
        build_error = (fun x -> Expr x) }
end
```

Maybe one day these changes will be generated automatically.

## How do I get an error resilient parser?

Given Menhir's interpreter `I` and the `IncrementalParser` it generates (roughly),
one has to provide a `Recovery`

```ocaml
module ERParser = Mastic.ErrorResilientParser.Make (I) (IncrementalParser) (Recovery)
let extra_tokens, ast = ERParser.parse lexbuf
```

Where `extra_tokens` are tokens not generaed by the `lexbuf` but rather by the
`Recovery` strategy. The main ingredient of `Recovery` is `handle_unexpected_token`.

```ocaml
type 'token tok = { s : string; t : 'token; b : Lexing.position; e : Lexing.position }
type ('token, 'production) recovery_action =
  | TurnIntoError
  | GenerateHole
  | GenerateToken of 'token tok
  | Reduce of 'production

val handle_unexpected_token :
  productions:(xsymbol * xsymbol list * production * int) list ->
  next_token:token tok ->
  acceptable_tokens:token tok list ->
  reducible_productions:production list ->
  generation_streak:int ->
  (token, production) recovery_action
```

That function receives a comprehensive description of the parser state
and must emit an action to recover parsing. `productions` are the parsing
rules for the current autmaton state while `next_token` is the offending
token.

- The `TurnIntoError` action is always possible and turns the offending token
into a lexing error (as if the token was not a valid one, just some text junk).
- The `Reduce` action forces a reduction for the given production. Only
`reducible_productions` can be used for that.
- The `GenerateHole` action generates an additional error token to complete the
production
- The `GenerateToken` generates a valid token, the ones being acceptable by the
automaton/recovery algorithm are given in `acceptable_tokens`

Actions that generate tokens should bound themselves, i.e. only be used if
`generation_streak` is smaller than a number (otherwise the parser can loop).

Example:

```ocaml
  let handle_unexpected_token ~productions ~next_token:tok ~acceptable_tokens
      ~reducible_productions:prods ~generation_streak =
    let open Mastic.ErrorResilientParser in
    match tok with
    (* tokens that look like a good point to re-start parsing (or terminate).
       these are typically the reserved words (keywords) of the language *)
    | { t = FUN | EOF | SEMICOLON | RPAREN | THEN | ELSE } -> begin
        match prods with
        | p :: _ ->
            (* if we can reduce we do it. it could be we are parsing something
               optional for example, but the next token is not a lookahead we exepct *)
            Reduce p
        | [] ->
            (* we try to complete one of the current productions *)
            match acceptable_tokens with
            | x :: _ ->
              (* this is a token that makes the automaton shift *)
              if generation_streak < 10 then GenerateToken x else TurnIntoError
            | [] ->
              (* this is a hole, the error production for the current nonterminal *)
              if generation_streak < 10 then GenerateHole else TurnIntoError
      end
    | _ ->
      TurnIntoError
```

The `handle_unexpected_token` above

```shell
$ echo 'fun f ( x := 3 + * )' | dune exec test/main.exe -- 
input: fun f ( x := 3 + * )
error:                  ^^  recovered syntax error
ast: (Ast.Prog.P
   [(Ast.Func.Fun ("f",
       [(Ast.Cmd.Assign ("x",
           (Ast.Expr.Add ((Ast.Expr.Lit 3), (Ast.Expr.Err [('*',17,18)])))))]
       ))])
```
Since it turned the offending token `*` into an error.

```shell
$ echo 'fun f ( x := 3 +  )' | dune exec test/main.exe -- 
input: fun f ( x := 3 +  )
error:                   ^ recovered syntax error
error:                   ^ completed with _
ast: (Ast.Prog.P
   [(Ast.Func.Fun ("f",
       [(Ast.Cmd.Assign ("x",
           (Ast.Expr.Add ((Ast.Expr.Lit 3), (Ast.Expr.Err [('_',18,18)])))))]
       ))])
```
Since it completed with a hole having encountered `RPAREN`.

If instead we opt for the most basic strategy, i.e. turning all unexpected
tokens into errors

```ocaml
  let handle_unexpected_token ~productions ~next_token:tok ~acceptable_tokens
      ~reducible_productions:prods ~generation_streak = TurnIntoError
```

we get:

```shell
$ echo 'fun f ( x := 3 +  )' | dune exec test/main.exe -- 
input: fun f ( x := 3 +  )
error: ^^^^^^^^^^^^^  ^^ ^ recovered syntax error
ast: (Ast.Prog.P
   [(Ast.Func.Err
       [('fun',0,3); ('ident',4,5);
         ((Ast.Cmd.Err
             [('ident',8,9);
               ((Ast.Expr.Err
                   [((Ast.Expr.Lit 3),13,14);
                     ((Ast.Expr.Err [(')',18,19)]),18,19); ('+',15,16)]),13,19);
               (':=',10,12)]),8,19); ('(',6,7)])])
```

Still note that the AST contains all the tokens.

## Real grammars

Two directories apply Mastic to the parser of a real language, step by step,
and measure the quality of the recovery on thousands of damaged programs
(precision, recall and F1 of the nodes of the recovered syntax tree):

- [`test_elpi`](test_elpi/README.md): the parser of Elpi;
- [`test_jazz`](test_jazz/README.md): the parser of Jasmin.

## What is the status of this software?

EXPERIMENTAL


