The hand-written cases: one kind of syntax error each, compared with the
good program it comes from (cases/*.ref), see the measure in main.ml

  $ ./main.exe -ref cases/01_op_no_rhs.ref cases/01_op_no_rhs.elpi
  input: p 1.
         p X :- X is 2 + .
  error:                 ^ recovered syntax error
         p 3.
  error: line 2, column 16: completed with _
  ast:
    clause (p 1)
    clause (:- (p X) (is X (+ 2 Err«»)))
    clause (p 3)
  measure: precision 100.0% (20/20) recall 100.0% (20/20) F1 100.0%
  $ ./main.exe -ref cases/02_op_no_lhs.ref cases/02_op_no_lhs.elpi
  input: p 1.
         p X :- X is * 3.
  error:             ^    recovered syntax error
         p 3.
  error: line 2, column 12: completed with _
  ast:
    clause (p 1)
    clause (:- (p X) (is X (* Err«» 3)))
    clause (p 3)
  measure: precision 100.0% (20/20) recall 100.0% (20/20) F1 100.0%
  $ ./main.exe -ref cases/03_open_paren.ref cases/03_open_paren.elpi
  input: p 1.
         p X :- q (X, r.
         p 3.
  error: line 2, column 14: completed with )
  ast:
    clause (p 1)
    clause (:- (p X) (q (, X r)))
    clause (p 3)
  measure: precision 100.0% (20/20) recall 100.0% (20/20) F1 100.0%
  $ ./main.exe -ref cases/04_close_paren.ref cases/04_close_paren.elpi
  input: p 1.
         p X :- q X), r.
         p 3.
  error: line 2, column 10: skipped )
  ast:
    clause (p 1)
    clause (:- (p X) (, (q X) r))
    clause (p 3)
  measure: precision 100.0% (20/20) recall 100.0% (20/20) F1 100.0%
  $ ./main.exe -ref cases/05_open_bracket.ref cases/05_open_bracket.elpi
  input: p 1.
         p [X|Y :- q X.
         p 3.
  error: line 2, column 6: completed with ]
  ast:
    clause (p 1)
    clause (:- (p (:: X Y)) (q X))
    clause (p 3)
  measure: precision 100.0% (20/20) recall 100.0% (20/20) F1 100.0%
  $ ./main.exe -ref cases/06_bad_list_tail.ref cases/06_bad_list_tail.elpi
  input: p 1.
         p [X|] :- q X.
  error:      ^         recovered syntax error
         p 3.
  error: line 2, column 5: completed with _
  ast:
    clause (p 1)
    clause (:- (p (:: X Err«»)) (q X))
    clause (p 3)
  measure: precision 100.0% (19/19) recall 100.0% (19/19) F1 100.0%
  $ ./main.exe -ref cases/07_open_brace.ref cases/07_open_brace.elpi
  input: p 1.
         p X :- q {r X.
         p 3.
  error: line 2, column 13: completed with }
  ast:
    clause (p 1)
    clause (:- (p X) (q (%spill (r X))))
    clause (p 3)
  measure: precision 100.0% (21/21) recall 100.0% (21/21) F1 100.0%
  $ ./main.exe -ref cases/08_missing_dot.ref cases/08_missing_dot.elpi
  input: p 1.
         p 2
         p 3.
  ast:
    clause (p 1)
    clause (p 2 p 3)
  measure: precision 80.0% (8/10) recall 66.7% (8/12) F1 72.7%
  $ ./main.exe -ref cases/09_missing_dot_rule.ref cases/09_missing_dot_rule.elpi
  input: p 1.
         p X :- q X
         p 3 :- r.
         p 4.
  ast:
    clause (p 1)
    clause (:- (p X) (:- (q X p 3) r))
    clause (p 4)
  measure: precision 81.8% (18/22) recall 75.0% (18/24) F1 78.3%
  $ ./main.exe -ref cases/10_double_dot.ref cases/10_double_dot.elpi
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
  measure: precision 100.0% (12/12) recall 100.0% (12/12) F1 100.0%
  $ ./main.exe -ref cases/11_empty_body.ref cases/11_empty_body.elpi
  input: p 1.
         p X :- .
  error:        ^ recovered syntax error
         p 3.
  error: line 2, column 7: completed with _
  ast:
    clause (p 1)
    clause (:- (p X) Err«»)
    clause (p 3)
  measure: precision 100.0% (14/14) recall 100.0% (14/14) F1 100.0%
  $ ./main.exe -ref cases/12_trailing_comma.ref cases/12_trailing_comma.elpi
  input: p 1.
         p X :- q X, .
  error:             ^ recovered syntax error
         p 3.
  error: line 2, column 12: completed with _
  ast:
    clause (p 1)
    clause (:- (p X) (, (q X) Err«»))
    clause (p 3)
  measure: precision 100.0% (19/19) recall 100.0% (19/19) F1 100.0%
  $ ./main.exe -ref cases/13_lambda_no_body.ref cases/13_lambda_no_body.elpi
  input: p 1.
         p F :- F = x\ .
  error:               ^ recovered syntax error
         p 3.
  error: line 2, column 14: completed with _
  ast:
    clause (p 1)
    clause (:- (p F) (= F x\ Err«»))
    clause (p 3)
  measure: precision 100.0% (18/18) recall 100.0% (18/18) F1 100.0%
  $ ./main.exe -ref cases/14_lex_dollar.ref cases/14_lex_dollar.elpi
  input: p 1.
         p $ 2.
  error:   ^    recovered syntax error
         p 3.
  error: unexpected character $ lexical error
  ast:
    clause (p 1)
    clause (p Err«$» 2)
    clause (p 3)
  measure: precision 100.0% (12/12) recall 100.0% (12/12) F1 100.0%
  $ ./main.exe -ref cases/15_lex_hash.ref cases/15_lex_hash.elpi
  input: p 1.
         p # 2.
         p 3.
  ast:
    clause (p 1)
    clause (# p 2)
    clause (p 3)
  measure: precision 91.7% (11/12) recall 91.7% (11/12) F1 91.7%
  $ ./main.exe -ref cases/16_string_unclosed.ref cases/16_string_unclosed.elpi
  input: p 1.
         p "abc.
  error:   ^     recovered syntax error
         p 3.
  error: missing terminator for string starting here lexical error
  ast:
    clause (p 1)
    clause (p Err«"» abc)
    clause (p 3)
  measure: precision 91.7% (11/12) recall 91.7% (11/12) F1 91.7%
  $ ./main.exe -ref cases/17_comment_unclosed.ref cases/17_comment_unclosed.elpi
  input: p 1.
         /* p 2.
  error: ^^      recovered syntax error
         p 3.
  error: missing terminator for comment starting here lexical error
  ast:
    clause (p 1)
    error Err«/*»
    clause (p 2)
    clause (p 3)
  measure: precision 100.0% (12/12) recall 100.0% (12/12) F1 100.0%
  $ ./main.exe -ref cases/18_pred_no_mode.ref cases/18_pred_no_mode.elpi
  input: p 1.
         pred q i:.
  error:          ^ recovered syntax error
         p 3.
  error: line 2, column 9: completed with _
  ast:
    clause (p 1)
    pred q (pred i:Err«»)
    clause (p 3)
  measure: precision 100.0% (10/10) recall 100.0% (10/10) F1 100.0%
  $ ./main.exe -ref cases/19_pred_no_type.ref cases/19_pred_no_type.elpi
  input: p 1.
         pred q i:int, o:.
  error:                 ^ recovered syntax error
         p 3.
  error: line 2, column 16: completed with _
  ast:
    clause (p 1)
    pred q (pred i:int, o:Err«»)
    clause (p 3)
  measure: precision 100.0% (11/11) recall 100.0% (11/11) F1 100.0%
  $ ./main.exe -ref cases/20_type_no_arrow.ref cases/20_type_no_arrow.elpi
  input: p 1.
         type c int ->.
  error:              ^ recovered syntax error
         p 3.
  error: line 2, column 13: completed with _
  ast:
    clause (p 1)
    type c (int -> Err«»)
    clause (p 3)
  measure: precision 100.0% (11/11) recall 100.0% (11/11) F1 100.0%
  $ ./main.exe -ref cases/21_kind_bad.ref cases/21_kind_bad.elpi
  input: p 1.
         kind t.
         p 3.
  error: line 2, column 6: completed with _
  ast:
    clause (p 1)
    kind t
    clause (p 3)
  measure: precision 100.0% (9/9) recall 100.0% (9/9) F1 100.0%
  $ ./main.exe -ref cases/22_namespace_open.ref cases/22_namespace_open.elpi
  input: p 1.
         namespace foo {
         p 2.
  ast:
    clause (p 1)
    namespace foo {
    clause (p 2)
  measure: precision 100.0% (9/9) recall 100.0% (9/9) F1 100.0%
  $ ./main.exe -ref cases/23_namespace_no_name.ref cases/23_namespace_no_name.elpi
  input: p 1.
         namespace {
  error: ^^^^^^^^^^^ recovered syntax error
         p 2.
         }
         p 3.
  ast:
    clause (p 1)
    error Err«namespace {»
    clause (p 2)
    }
    clause (p 3)
  measure: precision 100.0% (13/13) recall 92.9% (13/14) F1 96.3%
  $ ./main.exe -ref cases/24_extra_close_block.ref cases/24_extra_close_block.elpi
  input: p 1.
         }
         p 3.
  ast:
    clause (p 1)
    }
    clause (p 3)
  measure: precision 100.0% (8/8) recall 100.0% (8/8) F1 100.0%
  $ ./main.exe -ref cases/25_eof_in_body.ref cases/25_eof_in_body.elpi
  input: p 1.
         p X :- q X,
  error: line 2, column 11: completed with _
  error: line 2, column 11: completed with .
  ast:
    clause (p 1)
    clause (:- (p X) (, (q X) Err«»))
  measure: precision 100.0% (15/15) recall 100.0% (15/15) F1 100.0%
  $ ./main.exe -ref cases/26_eof_after_neck.ref cases/26_eof_after_neck.elpi
  input: p 1.
         p X :-
  error: line 2, column 6: completed with _
  error: line 2, column 6: completed with .
  ast:
    clause (p 1)
    clause (:- (p X) Err«»)
  measure: precision 100.0% (10/10) recall 100.0% (10/10) F1 100.0%
  $ ./main.exe -ref cases/27_eof_in_pred.ref cases/27_eof_in_pred.elpi
  input: p 1.
         pred q i:
  error: line 2, column 9: completed with _
  error: line 2, column 9: completed with .
  ast:
    clause (p 1)
    pred q (pred i:Err«»)
  measure: precision 100.0% (6/6) recall 100.0% (6/6) F1 100.0%
  $ ./main.exe -ref cases/28_two_errors.ref cases/28_two_errors.elpi
  input: p 1.
         p X :- X is 2 + .
  error:                 ^ recovered syntax error
         p 3.
         p Y :- q (Y.
         p 5.
  error: line 2, column 16: completed with _
  error: line 4, column 11: completed with )
  ast:
    clause (p 1)
    clause (:- (p X) (is X (+ 2 Err«»)))
    clause (p 3)
    clause (:- (p Y) (q Y))
    clause (p 5)
  measure: precision 100.0% (20/20) recall 100.0% (20/20) F1 100.0%
  $ ./main.exe -ref cases/29_error_in_long_clause.ref cases/29_error_in_long_clause.elpi
  input: p 1.
         p X :-
           q X,
           r X,
           s X X ),
           t X,
           u X.
         p 3.
  error: line 5, column 8: skipped )
  ast:
    clause (p 1)
    clause (:- (p X) (, (q X) (r X) (s X X) (t X) (u X)))
    clause (p 3)
  measure: precision 96.9% (31/32) recall 96.9% (31/32) F1 96.9%
  $ ./main.exe -ref cases/30_attribute_bad.ref cases/30_attribute_bad.elpi
  input: :name 3
  error:  ^^^^^^ recovered syntax error
         p 1.
         p 2.
  ast:
    clause :Err«name 3» (p 1)
    clause (p 2)
  measure: precision 100.0% (8/8) recall 100.0% (8/8) F1 100.0%
  $ ./main.exe -ref cases/31_infix_dangling.ref cases/31_infix_dangling.elpi
  input: p 1.
         p X :- q X; .
  error:             ^ recovered syntax error
         p 3.
  error: line 2, column 12: completed with _
  ast:
    clause (p 1)
    clause (:- (p X) (; (q X) Err«»))
    clause (p 3)
  measure: precision 100.0% (19/19) recall 100.0% (19/19) F1 100.0%
  $ ./main.exe -ref cases/32_infix_no_lhs.ref cases/32_infix_no_lhs.elpi
  input: p :- X is + 2 * 3.
  error:           ^        recovered syntax error
  error: line 1, column 10: completed with _
  ast:
    clause (:- p (is X (+ Err«» (* 2 3))))
  measure: precision 100.0% (13/13) recall 100.0% (13/13) F1 100.0%
