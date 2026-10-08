Fuzzing, as in test/: a character is replaced by ';', ' ' or '$'

  $ printf 'fn f(reg u64 x) -> reg u64 {\n  x = x + 2 * 3;\n  return x;\n}\n' | ./main.exe -fuzz 10 -rands 0,3,9,15,22,30,34,38,45,52
  random: 0,3,9,15,22,30,34,38,45,52
  input: fn f(reg u64 x) -> reg u64 {
           x = x + 2 * 3;
           return x;
         }
  ast:
    fn f(reg u64 x) -> reg u64
      x = (+ x (* 2 3))
      return x
  
  fuzzed input #1: ;n f(reg u64 x) -> reg u64 {
  error:           ^^^^^^^^^^^^^^^^^^^^^^^^^^^  recovered syntax error
                     x = x + 2 * 3;
                     return x;
                   }
  error: line 1, column 0: completed with _
  error: line 1, column 27: completed with _
  ast:
    error Err«;n f(reg u64 x) -> reg»
    fn Err« u64 »
      x = (+ x (* 2 3))
      return x
  note: not a subterm
  measure: precision 90.0% (9/10) recall 60.0% (9/15) F1 72.0%
  
  fuzzed input #2: fn ;(reg u64 x) -> reg u64 {
  error:              ^^^^^^^^^^^^^^^ ^^^^^^^^  recovered syntax error
                     x = x + 2 * 3;
                     return x;
                   }
  error: line 1, column 3: completed with _
  error: line 1, column 3: completed with {
  error: line 1, column 27: completed with _
  error: line 1, column 27: completed with _
  error: line 3, column 2: completed with }
  ast:
    fn Err«»
      Err«;(reg u64 x) ->»
      Err«reg u64 »
        x = (+ x (* 2 3))
      return x
  note: not a subterm
  measure: precision 75.0% (9/12) recall 60.0% (9/15) F1 66.7%
  
  fuzzed input #3: fn f(reg ;64 x) -> reg u64 {
  error:              ^^^^^^^^^^^^^^^ ^^^^^^^^  recovered syntax error
                     x = x + 2 * 3;
                     return x;
                   }
  error: line 1, column 9: completed with _
  error: line 1, column 9: completed with _
  error: line 1, column 9: completed with {
  error: line 1, column 27: completed with _
  error: line 1, column 27: completed with _
  error: line 3, column 2: completed with }
  ast:
    fn Err«f(reg »
      Err«;64 x) ->»
      Err«reg u64 »
        x = (+ x (* 2 3))
      return x
  note: not a subterm
  measure: precision 75.0% (9/12) recall 60.0% (9/15) F1 66.7%
  
  fuzzed input #4: fn f(reg u64 x);-> reg u64 {
  error:                          ^^^ ^^^^^^^^  recovered syntax error
                     x = x + 2 * 3;
                     return x;
                   }
  error: line 1, column 15: completed with {
  error: line 1, column 27: completed with _
  error: line 1, column 27: completed with _
  error: line 3, column 2: completed with }
  ast:
    fn f(reg u64 x)
      Err«;->»
      Err«reg u64 »
        x = (+ x (* 2 3))
      return x
  note: not a subterm
  measure: precision 86.7% (13/15) recall 86.7% (13/15) F1 86.7%
  
  fuzzed input #5: fn f(reg u64 x) -> reg u64 {
                     x = x + 2 * 3;
                     return x;
                   }
  ast:
    fn f(reg u64 x) -> reg u64
      x = (+ x (* 2 3))
      return x
  measure: precision 100.0% (15/15) recall 100.0% (15/15) F1 100.0%
  
  fuzzed input #6: fn f(reg u64 x) -> reg u64 {
                    ;x = x + 2 * 3;
  error:            ^               recovered syntax error
                     return x;
                   }
  ast:
    fn f(reg u64 x) -> reg u64
      Err«;»
      x = (+ x (* 2 3))
      return x
  note: not a subterm
  measure: precision 100.0% (15/15) recall 100.0% (15/15) F1 100.0%
  
  fuzzed input #7: fn f(reg u64 x) -> reg u64 {
                     x = x + 2 * 3;
                     return x;
                   }
  ast:
    fn f(reg u64 x) -> reg u64
      x = (+ x (* 2 3))
      return x
  measure: precision 100.0% (15/15) recall 100.0% (15/15) F1 100.0%
  
  fuzzed input #8: fn f(reg u64 x) -> reg u64 {
                     x = x +$2 * 3;
  error:                 ^^^^^      recovered syntax error
                     return x;
                   }
  error: invalid char: `$' lexical error
  ast:
    fn f(reg u64 x) -> reg u64
      x = (* Err«x +$2» 3)
      return x
  note: not a subterm
  measure: precision 91.7% (11/12) recall 73.3% (11/15) F1 81.5%
  
  fuzzed input #9: fn f(reg u64 x) -> reg u64 {
                     x = x + 2 * 3;;  return x;
  error:                           ^            recovered syntax error
                   }
  ast:
    fn f(reg u64 x) -> reg u64
      x = (+ x (* 2 3))
      Err«;»
      return x
  note: not a subterm
  measure: precision 100.0% (15/15) recall 100.0% (15/15) F1 100.0%
  
  fuzzed input #10: fn f(reg u64 x) -> reg u64 {
                      x = x + 2 * 3;
                      retu n x;
  error:              ^^^^^^^^^ recovered syntax error
                    }
  error: line 3, column 10: completed with _
  error: line 3, column 10: completed with _
  error: line 3, column 10: completed with _
  error: line 3, column 10: completed with (error)
  ast:
    fn f(reg u64 x) -> reg u64
      x = (+ x (* 2 3))
      Err«retu n x;»
  measure: precision 100.0% (13/13) recall 86.7% (13/15) F1 92.9%
  

  $ printf 'param int N = 4;\nfn g(reg u64 a) {\n  if (a > N) {\n    a = [:u64 a + 8];\n  }\n}\n' | ./main.exe -fuzz 10 -rands 2,11,20,27,33,40,48,55,63,70
  random: 2,11,20,27,33,40,48,55,63,70
  input: param int N = 4;
         fn g(reg u64 a) {
           if (a > N) {
             a = [:u64 a + 8];
           }
         }
  ast:
    param int N = 4
    fn g(reg u64 a)
      if (> a N)
        a = [:u64 (+ a 8)]
  
  fuzzed input #1: pa$am int N = 4;
  error:           ^^^^^^^^^^^^^^^^ recovered syntax error
                   fn g(reg u64 a) {
                     if (a > N) {
                       a = [:u64 a + 8];
                     }
                   }
  error: invalid char: `$' lexical error
  ast:
    error Err«pa$am int N = 4;»
    fn g(reg u64 a)
      if (> a N)
        a = [:u64 (+ a 8)]
  measure: precision 100.0% (15/15) recall 83.3% (15/18) F1 90.9%
  
  fuzzed input #2: param int N$= 4;
  error:           ^^^^^^^^^^^^^^^^ recovered syntax error
                   fn g(reg u64 a) {
                     if (a > N) {
                       a = [:u64 a + 8];
                     }
                   }
  error: invalid char: `$' lexical error
  error: line 1, column 15: completed with _
  error: line 1, column 15: completed with _
  error: line 1, column 15: completed with _
  error: line 1, column 15: completed with (error)
  ast:
    error Err«param int N$= 4;»
    fn g(reg u64 a)
      if (> a N)
        a = [:u64 (+ a 8)]
  measure: precision 100.0% (15/15) recall 83.3% (15/18) F1 90.9%
  
  fuzzed input #3: param int N = 4;
                   fn $(reg u64 a) {
  error:              ^^^^^^^^^^^^   recovered syntax error
                     if (a > N) {
                       a = [:u64 a + 8];
                     }
                   }
  error: invalid char: `$' lexical error
  ast:
    param int N = 4
    fn Err«$(reg u64 a)»
      if (> a N)
        a = [:u64 (+ a 8)]
  note: not a subterm
  measure: precision 93.3% (14/15) recall 77.8% (14/18) F1 84.8%
  
  fuzzed input #4: param int N = 4;
                   fn g(reg u;4 a) {
  error:              ^^^^^^^^^ ^^   recovered syntax error
                     if (a > N) {
                       a = [:u64 a + 8];
                     }
                   }
  error: line 2, column 10: completed with _
  error: line 2, column 10: completed with _
  error: line 2, column 10: completed with {
  error: line 7, column 0: completed with }
  ast:
    param int N = 4
    fn Err«g(reg u»
      Err«;4»
      Err«a)»
        if (> a N)
          a = [:u64 (+ a 8)]
  note: not a subterm
  measure: precision 82.4% (14/17) recall 77.8% (14/18) F1 80.0%
  
  fuzzed input #5: param int N = 4;
                   fn g(reg u64 a) ;
  error:                           ^ recovered syntax error
                     if (a > N) {
                       a = [:u64 a + 8];
                     }
                   }
  error: line 2, column 16: completed with {
  ast:
    param int N = 4
    fn g(reg u64 a)
      Err«;»
      if (> a N)
        a = [:u64 (+ a 8)]
  note: not a subterm
  measure: precision 100.0% (18/18) recall 100.0% (18/18) F1 100.0%
  
  fuzzed input #6: param int N = 4;
                   fn g(reg u64 a) {
                     if  a > N) {
  error:                 ^^^^^^   recovered syntax error
                       a = [:u64 a + 8];
                     }
                   }
  ast:
    param int N = 4
    fn g(reg u64 a)
      if Err«a > N)»
        a = [:u64 (+ a 8)]
  measure: precision 100.0% (15/15) recall 83.3% (15/18) F1 90.9%
  
  fuzzed input #7: param int N = 4;
                   fn g(reg u64 a) {
                     if (a > N) ;
  error:                        ^ recovered syntax error
                       a = [:u64 a + 8];
                     }
                   }
  error: line 3, column 13: completed with {
  ast:
    param int N = 4
    fn g(reg u64 a)
      if (> a N)
        Err«;»
        a = [:u64 (+ a 8)]
  note: not a subterm
  measure: precision 100.0% (18/18) recall 100.0% (18/18) F1 100.0%
  
  fuzzed input #8: param int N = 4;
                   fn g(reg u64 a) {
                     if (a > N) {
                       a = [:u64 a + 8];
                     }
                   }
  ast:
    param int N = 4
    fn g(reg u64 a)
      if (> a N)
        a = [:u64 (+ a 8)]
  measure: precision 100.0% (18/18) recall 100.0% (18/18) F1 100.0%
  
  fuzzed input #9: param int N = 4;
                   fn g(reg u64 a) {
                     if (a > N) {
                       a = [:u64;a + 8];
  error:                        ^^^^^^^^ recovered syntax error
                     }
                   }
  error: line 4, column 13: completed with _
  error: line 4, column 13: completed with ]
  error: line 4, column 20: completed with _
  error: line 4, column 20: completed with _
  error: line 4, column 20: completed with _
  error: line 4, column 20: completed with (error)
  ast:
    param int N = 4
    fn g(reg u64 a)
      if (> a N)
        a = [:u64 Err«»]
        Err«a + 8];»
  note: not a subterm
  measure: precision 86.7% (13/15) recall 72.2% (13/18) F1 78.8%
  
  fuzzed input #10: param int N = 4;
                    fn g(reg u64 a) {
                      if (a > N) {
                        a = [:u64 a + 8] 
                      }
                    }
  error: line 5, column 2: completed with ;
  ast:
    param int N = 4
    fn g(reg u64 a)
      if (> a N)
        a = [:u64 (+ a 8)]
  measure: precision 94.4% (17/18) recall 94.4% (17/18) F1 94.4%
  
