The hand-written cases: one kind of syntax error each, compared with the
good program it comes from (cases/*.ref), see the measure in main.ml

  $ ./main.exe -ref cases/01_op_no_rhs.ref cases/01_op_no_rhs.jazz
  input: fn f(reg u64 x) -> reg u64 {
           reg u64 y;
           y = x + ;
  error:           ^ recovered syntax error
           y = y * 2;
           return y;
         }
  error: line 3, column 10: completed with _
  ast:
    fn f(reg u64 x) -> reg u64
      reg u64 y
      y = (+ x Err«»)
      y = (* y 2)
      return y
  measure: precision 100.0% (21/21) recall 100.0% (21/21) F1 100.0%
  $ ./main.exe -ref cases/02_op_no_lhs.ref cases/02_op_no_lhs.jazz
  input: fn f(reg u64 x) -> reg u64 {
           reg u64 y;
           y = x + 1;
           y = * 2;
  error:       ^    recovered syntax error
           return y;
         }
  error: line 4, column 6: completed with _
  ast:
    fn f(reg u64 x) -> reg u64
      reg u64 y
      y = (+ x 1)
      y = (* Err«» 2)
      return y
  measure: precision 100.0% (21/21) recall 100.0% (21/21) F1 100.0%
  $ ./main.exe -ref cases/03_open_paren.ref cases/03_open_paren.jazz
  input: fn f(reg u64 x) -> reg u64 {
           reg u64 y;
           y = (x + 1 * 2;
           y += 3;
           return y;
         }
  error: line 3, column 16: completed with )
  ast:
    fn f(reg u64 x) -> reg u64
      reg u64 y
      y = (+ x (* 1 2))
      y += 3
      return y
  measure: precision 90.9% (20/22) recall 90.9% (20/22) F1 90.9%
  $ ./main.exe -ref cases/04_close_paren.ref cases/04_close_paren.jazz
  input: fn f(reg u64 x) -> reg u64 {
           reg u64 y;
           y = x + 1) * 2;
  error:       ^^^^^^      recovered syntax error
           y += 3;
           return y;
         }
  ast:
    fn f(reg u64 x) -> reg u64
      reg u64 y
      y = (* Err«x + 1)» 2)
      y += 3
      return y
  measure: precision 100.0% (19/19) recall 86.4% (19/22) F1 92.7%
  $ ./main.exe -ref cases/05_open_bracket.ref cases/05_open_bracket.jazz
  input: fn f(reg u64 x) -> reg u64 {
           reg u64 y;
           y = [:u64 x + 8;
           y += 3;
           return y;
         }
  error: line 3, column 17: completed with ]
  ast:
    fn f(reg u64 x) -> reg u64
      reg u64 y
      y = [:u64 (+ x 8)]
      y += 3
      return y
  measure: precision 100.0% (21/21) recall 100.0% (21/21) F1 100.0%
  $ ./main.exe -ref cases/06_missing_semicolon.ref cases/06_missing_semicolon.jazz
  input: fn f(reg u64 x) -> reg u64 {
           reg u64 y;
           y = x + 1
           y = y * 2;
           return y;
         }
  error: line 4, column 2: completed with ;
  ast:
    fn f(reg u64 x) -> reg u64
      reg u64 y
      y = (+ x 1)
      y = (* y 2)
      return y
  measure: precision 95.5% (21/22) recall 95.5% (21/22) F1 95.5%
  $ ./main.exe -ref cases/07_missing_semicolon_eol.ref cases/07_missing_semicolon_eol.jazz
  input: fn f(reg u64 x) -> reg u64 {
           reg u64 y;
           y = x + 1;
           y = y * 2
           return y;
         }
  error: line 5, column 2: completed with ;
  ast:
    fn f(reg u64 x) -> reg u64
      reg u64 y
      y = (+ x 1)
      y = (* y 2)
      return y
  measure: precision 95.5% (21/22) recall 95.5% (21/22) F1 95.5%
  $ ./main.exe -ref cases/08_double_semicolon.ref cases/08_double_semicolon.jazz
  input: fn f(reg u64 x) -> reg u64 {
           reg u64 y;
           y = x + 1;;
  error:             ^ recovered syntax error
           y = y * 2;
           return y;
         }
  ast:
    fn f(reg u64 x) -> reg u64
      reg u64 y
      y = (+ x 1)
      Err«;»
      y = (* y 2)
      return y
  measure: precision 100.0% (22/22) recall 100.0% (22/22) F1 100.0%
  $ ./main.exe -ref cases/09_missing_close_brace_if.ref cases/09_missing_close_brace_if.jazz
  input: fn f(reg u64 x) -> reg u64 {
           reg u64 y;
           if (x > 0) {
             y = 1;
           y += 2;
           return y;
         }
  error: line 6, column 2: completed with }
  ast:
    fn f(reg u64 x) -> reg u64
      reg u64 y
      if (> x 0)
        y = 1
        y += 2
      return y
  measure: precision 91.3% (21/23) recall 91.3% (21/23) F1 91.3%
  $ ./main.exe -ref cases/10_missing_open_brace_if.ref cases/10_missing_open_brace_if.jazz
  input: fn f(reg u64 x) -> reg u64 {
           reg u64 y;
           if (x > 0)
             y = 1;
           }
           y += 2;
           return y;
         }
  error: line 4, column 4: completed with {
  ast:
    fn f(reg u64 x) -> reg u64
      reg u64 y
      if (> x 0)
        y = 1
      y += 2
      return y
  measure: precision 95.7% (22/23) recall 95.7% (22/23) F1 95.7%
  $ ./main.exe -ref cases/11_extra_close_brace.ref cases/11_extra_close_brace.jazz
  input: fn f(reg u64 x) -> reg u64 {
           reg u64 y;
           y = x + 1;
           }
           y = y * 2;
  error: ^^^^^^^^^^^^ recovered syntax error
           return y;
  error: ^^^^^^^^^^^ recovered syntax error
         }
  error: ^ recovered syntax error
  error: line 6, column 10: completed with _
  ast:
    fn f(reg u64 x) -> reg u64
      reg u64 y
      y = (+ x 1)
    error Err«   y = y * 2;   return y; }»
  measure: precision 93.3% (14/15) recall 63.6% (14/22) F1 75.7%
  $ ./main.exe -ref cases/12_missing_fn_close.ref cases/12_missing_fn_close.jazz
  input: fn f(reg u64 x) -> reg u64 {
           reg u64 y;
           y = x + 1;
           return y;
         
         fn g(reg u64 a) -> reg u64 {
           a += 1;
           return a;
         }
  error: line 6, column 0: completed with }
  ast:
    fn f(reg u64 x) -> reg u64
      reg u64 y
      y = (+ x 1)
      return y
    fn g(reg u64 a) -> reg u64
      a += 1
      return a
  measure: precision 92.9% (26/28) recall 92.9% (26/28) F1 92.9%
  $ ./main.exe -ref cases/13_if_no_condition.ref cases/13_if_no_condition.jazz
  input: fn f(reg u64 x) -> reg u64 {
           reg u64 y;
           if {
  error:      ^ recovered syntax error
             y = 1;
           }
           return y;
         }
  error: line 3, column 5: completed with _
  ast:
    fn f(reg u64 x) -> reg u64
      reg u64 y
      if Err«»
        y = 1
      return y
  measure: precision 100.0% (17/17) recall 100.0% (17/17) F1 100.0%
  $ ./main.exe -ref cases/14_for_no_var.ref cases/14_for_no_var.jazz
  input: fn f(reg u64 x) -> reg u64 {
           reg u64 y;
           inline int i;
           for = 0 to 4 {
  error:   ^^^^^^^^^^^^   recovered syntax error
             y += x;
           }
           return y;
         }
  ast:
    fn f(reg u64 x) -> reg u64
      reg u64 y
      inline int i
      Err«for = 0 to 4»
        y += x
      return y
  measure: precision 95.2% (20/21) recall 87.0% (20/23) F1 90.9%
  $ ./main.exe -ref cases/15_while_no_paren.ref cases/15_while_no_paren.jazz
  input: fn f(reg u64 x) -> reg u64 {
           reg u64 y;
           while (y > 0 {
             y -= 1;
           }
           return y;
         }
  error: line 3, column 15: completed with )
  ast:
    fn f(reg u64 x) -> reg u64
      reg u64 y
      while
      ((> y 0))
        y -= 1
      return y
  measure: precision 100.0% (20/20) recall 100.0% (20/20) F1 100.0%
  $ ./main.exe -ref cases/16_decl_no_type.ref cases/16_decl_no_type.jazz
  input: fn f(reg u64 x) -> reg u64 {
           reg u64 y;
           reg z;
  error:   ^^^^^^ recovered syntax error
           z = y;
           y = z;
           return y;
         }
  error: line 3, column 7: completed with _
  error: line 3, column 7: completed with _
  error: line 3, column 7: completed with _
  error: line 3, column 7: completed with (error)
  ast:
    fn f(reg u64 x) -> reg u64
      reg u64 y
      Err«reg z;»
      z = y
      y = z
      return y
  measure: precision 100.0% (18/18) recall 90.0% (18/20) F1 94.7%
  $ ./main.exe -ref cases/17_decl_no_var.ref cases/17_decl_no_var.jazz
  input: fn f(reg u64 x) -> reg u64 {
           reg u64 y;
           reg u64 ;
  error:   ^^^^^^^^^ recovered syntax error
           y = x;
           return y;
         }
  error: line 3, column 10: completed with _
  error: line 3, column 10: completed with _
  error: line 3, column 10: completed with _
  error: line 3, column 10: completed with (error)
  ast:
    fn f(reg u64 x) -> reg u64
      reg u64 y
      Err«reg u64 ;»
      y = x
      return y
  measure: precision 100.0% (15/15) recall 83.3% (15/18) F1 90.9%
  $ ./main.exe -ref cases/18_lex_dollar.ref cases/18_lex_dollar.jazz
  input: fn f(reg u64 x) -> reg u64 {
           reg u64 y;
           y = x $ 1;
  error:       ^^^^^  recovered syntax error
           y = y * 2;
           return y;
         }
  error: invalid char: `$' lexical error
  ast:
    fn f(reg u64 x) -> reg u64
      reg u64 y
      y = Err«x $ 1»
      y = (* y 2)
      return y
  measure: precision 100.0% (19/19) recall 86.4% (19/22) F1 92.7%
  $ ./main.exe -ref cases/19_lex_backquote.ref cases/19_lex_backquote.jazz
  input: fn f(reg u64 x) -> reg u64 {
           reg u64 y;
           y = x + 1;`
  error:             ^ recovered syntax error
           y = y * 2;
           return y;
         }
  error: invalid char: ``' lexical error
  ast:
    fn f(reg u64 x) -> reg u64
      reg u64 y
      y = (+ x 1)
      Err«`»
      y = (* y 2)
      return y
  measure: precision 100.0% (22/22) recall 100.0% (22/22) F1 100.0%
  $ ./main.exe -ref cases/20_comment_unclosed.ref cases/20_comment_unclosed.jazz
  input: fn f(reg u64 x) -> reg u64 {
           reg u64 y;
           y = x + 1; /* one
  error:              ^^^^^^ recovered syntax error
           y = y * 2;
  error: ^^           recovered syntax error
           return y;
         }
  error: unterminated comment lexical error
  error: line 4, column 2: completed with ;
  error: line 4, column 2: completed with _
  error: line 4, column 2: completed with _
  error: line 4, column 2: completed with (error)
  ast:
    fn f(reg u64 x) -> reg u64
      reg u64 y
      y = (+ x 1)
      Err«/* one   »
      y = (* y 2)
      return y
  measure: precision 100.0% (22/22) recall 100.0% (22/22) F1 100.0%
  $ ./main.exe -ref cases/21_string_unclosed.ref cases/21_string_unclosed.jazz
  input: require "a.jazz
  error: ^^^^^^^^^^^^^^^ recovered syntax error
         fn f(reg u64 x) -> reg u64 {
           reg u64 y;
           y = x + 1;
           return y;
         }
  error: invalid char: `"' lexical error
  error: line 2, column 0: completed with _
  ast:
    error Err«require "a.jazz »
    fn f(reg u64 x) -> reg u64
      reg u64 y
      y = (+ x 1)
      return y
  measure: precision 94.1% (16/17) recall 84.2% (16/19) F1 88.9%
  $ ./main.exe -ref cases/22_eof_in_body.ref cases/22_eof_in_body.jazz
  input: fn f(reg u64 x) -> reg u64 {
           reg u64 y;
           y = x + 1;
           y = y * 
  error: line 5, column 0: completed with _
  error: line 5, column 0: completed with ;
  error: line 5, column 0: completed with }
  ast:
    fn f(reg u64 x) -> reg u64
      reg u64 y
      y = (+ x 1)
      y = (* y Err«»)
  measure: precision 84.2% (16/19) recall 84.2% (16/19) F1 84.2%
  $ ./main.exe -ref cases/23_eof_in_if.ref cases/23_eof_in_if.jazz
  input: fn f(reg u64 x) -> reg u64 {
           reg u64 y;
           if (x > 0) {
             y = 1;
  error: line 5, column 0: completed with }
  error: line 5, column 0: completed with }
  ast:
    fn f(reg u64 x) -> reg u64
      reg u64 y
      if (> x 0)
        y = 1
  measure: precision 100.0% (18/18) recall 100.0% (18/18) F1 100.0%
  $ ./main.exe -ref cases/24_eof_in_header.ref cases/24_eof_in_header.jazz
  input: param int N = 4;
         
         fn f(reg u64 x, reg u64
  error:    ^^^^^^^^^^^^^^^^^^^^ recovered syntax error
  error: line 4, column 0: completed with _
  error: line 4, column 0: completed with _
  error: line 4, column 0: completed with {
  error: line 4, column 0: completed with }
  ast:
    param int N = 4
    fn Err«f(reg u64 x, reg u64 »
  measure: precision 75.0% (3/4) recall 42.9% (3/7) F1 54.5%
  $ ./main.exe -ref cases/25_header_missing_comma.ref cases/25_header_missing_comma.jazz
  input: fn f(reg u64 x reg u64 z) -> reg u64 {
           x += z;
           return x;
         }
  error: line 1, column 15: completed with ,
  ast:
    fn f(reg u64 x, reg u64 z) -> reg u64
      x += z
      return x
  measure: precision 100.0% (14/14) recall 100.0% (14/14) F1 100.0%
  $ ./main.exe -ref cases/26_header_broken_name.ref cases/26_header_broken_name.jazz
  input: fn (reg u64 x) -> reg u64 {
  error:    ^^^^^^^^^^^^^^^^^^^^^^   recovered syntax error
           x += 1;
           return x;
         }
  ast:
    fn Err«(reg u64 x) -> reg u64»
      x += 1
      return x
  measure: precision 83.3% (5/6) recall 45.5% (5/11) F1 58.8%
  $ ./main.exe -ref cases/27_param_no_value.ref cases/27_param_no_value.jazz
  input: param int N = ;
  error:               ^ recovered syntax error
         param int M = 8;
         fn f(reg u64 x) -> reg u64 {
           reg u64 y;
           y = x;
           return y;
         }
  error: line 1, column 14: completed with _
  ast:
    param int N = Err«»
    param int M = 8
    fn f(reg u64 x) -> reg u64
      reg u64 y
      y = x
      return y
  measure: precision 100.0% (20/20) recall 100.0% (20/20) F1 100.0%
  $ ./main.exe -ref cases/28_global_broken.ref cases/28_global_broken.jazz
  input: u64 g = 5 5;
  error:         ^^^  recovered syntax error
         u64[2] t = {1, 2};
         fn f(reg u64 x) -> reg u64 {
           reg u64 y;
           y = x;
           return y;
         }
  ast:
    global u64 g = Err«5 5»
    global u64[2] t = {1, 2}
    fn f(reg u64 x) -> reg u64
      reg u64 y
      y = x
      return y
  measure: precision 100.0% (22/22) recall 95.7% (22/23) F1 97.8%
  $ ./main.exe -ref cases/29_call_unclosed.ref cases/29_call_unclosed.jazz
  input: fn f(reg u64 x) -> reg u64 {
           reg u64 y;
           y = g(x, y;
           y += 1;
           return y;
         }
  error: line 3, column 12: completed with )
  ast:
    fn f(reg u64 x) -> reg u64
      reg u64 y
      y = (g x y)
      y += 1
      return y
  measure: precision 100.0% (20/20) recall 100.0% (20/20) F1 100.0%
  $ ./main.exe -ref cases/30_two_errors.ref cases/30_two_errors.jazz
  input: fn f(reg u64 x) -> reg u64 {
           reg u64 y;
           y = x + ;
  error:           ^ recovered syntax error
           y = y * 2;
           y = - 3 3;
  error:       ^^^^^  recovered syntax error
           return y;
         }
  error: line 3, column 10: completed with _
  ast:
    fn f(reg u64 x) -> reg u64
      reg u64 y
      y = (+ x Err«»)
      y = (* y 2)
      y = Err«- 3 3»
      return y
  measure: precision 100.0% (17/17) recall 89.5% (17/19) F1 94.4%
  $ ./main.exe -ref cases/31_namespace_unclosed.ref cases/31_namespace_unclosed.jazz
  input: namespace A {
           param int N = 4;
         param int M = 8;
  error: line 4, column 0: completed with }
  ast:
    namespace A {
      param int N = 4
      param int M = 8
    }
  measure: precision 85.7% (6/7) recall 85.7% (6/7) F1 85.7%
  $ ./main.exe -ref cases/32_annotation_broken.ref cases/32_annotation_broken.jazz
  input: #[returnaddress=]
         fn f(reg u64 x) -> reg u64 {
           reg u64 y;
           y = x;
           return y;
         }
  error: line 2, column 0: completed with ]
  ast:
    #[returnaddress] fn f(reg u64 x) -> reg u64
      reg u64 y
      y = x
      return y
  measure: precision 100.0% (16/16) recall 100.0% (16/16) F1 100.0%
