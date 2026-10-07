Fuzzing, as in test/: a character is replaced by ';', ' ' or '$'

  $ echo 'p :- X is 2 + 3 * 4.' | ./main.exe -fuzz 10 -rands 0,3,5,7,10,12,14,16,18,19
  random: 0,3,5,7,10,12,14,16,18,19
  input: p :- X is 2 + 3 * 4.
  ast:
    clause (:- p (is X (+ 2 (* 3 4))))
  
  fuzzed input #1: ; :- X is 2 + 3 * 4.
  error:           ^^^^                 recovered syntax error
  error: line 1, column 0: completed with .
  error: line 1, column 0: completed with _
  ast:
    error Err«; :-»
    clause (is X (+ 2 (* 3 4)))
  note: not a subterm
  measure: precision 90.9% (10/11) recall 76.9% (10/13) F1 83.3%
  
  fuzzed input #2: p :; X is 2 + 3 * 4.
  error:             ^                  recovered syntax error
  ast:
    clause (; (p Err«:») (is X (+ 2 (* 3 4))))
  note: not a subterm
  measure: precision 85.7% (12/14) recall 85.7% (12/14) F1 85.7%
  
  fuzzed input #3: p :- $ is 2 + 3 * 4.
  error:                ^               recovered syntax error
  error: unexpected character $ lexical error
  ast:
    clause (:- p (is Err«$» (+ 2 (* 3 4))))
  measure: precision 100.0% (13/13) recall 100.0% (13/13) F1 100.0%
  
  fuzzed input #4: p :- X  s 2 + 3 * 4.
  ast:
    clause (:- p (+ (X s 2) (* 3 4)))
  note: not a subterm
  measure: precision 78.6% (11/14) recall 78.6% (11/14) F1 78.6%
  
  fuzzed input #5: p :- X is   + 3 * 4.
  error:                       ^        recovered syntax error
  error: line 1, column 12: completed with _
  ast:
    clause (:- p (is X (+ Err«» (* 3 4))))
  measure: precision 92.3% (12/13) recall 92.3% (12/13) F1 92.3%
  
  fuzzed input #6: p :- X is 2 ; 3 * 4.
  ast:
    clause (:- p (; (is X 2) (* 3 4)))
  note: not a subterm
  measure: precision 84.6% (11/13) recall 84.6% (11/13) F1 84.6%
  
  fuzzed input #7: p :- X is 2 + $ * 4.
  error:                         ^      recovered syntax error
  error: unexpected character $ lexical error
  ast:
    clause (:- p (is X (+ 2 (* Err«$» 4))))
  measure: precision 100.0% (13/13) recall 100.0% (13/13) F1 100.0%
  
  fuzzed input #8: p :- X is 2 + 3   4.
  error:                         ^^^^^  recovered syntax error
  ast:
    clause (:- p (is X (+ 2 Err«3   4»)))
  measure: precision 100.0% (10/10) recall 76.9% (10/13) F1 87.0%
  
  fuzzed input #9: p :- X is 2 + 3 * ;.
  error:                             ^^ recovered syntax error
  error: line 1, column 18: completed with _
  error: line 1, column 19: completed with _
  ast:
    clause (:- p (; (is X (+ 2 (* 3 Err«»))) Err«»))
  note: not a subterm
  measure: precision 92.9% (13/14) recall 100.0% (13/13) F1 96.3%
  
  fuzzed input #10: p :- X is 2 + 3 * 4 
  error: line 2, column 0: completed with .
  ast:
    clause (:- p (is X (+ 2 (* 3 4))))
  measure: precision 100.0% (14/14) recall 100.0% (14/14) F1 100.0%
  

  $ printf 'pred append i:list A, i:list A, o:list A.\nappend [] L L.\nappend [X|XS] L [X|R] :- append XS L R.\n' | ./main.exe -fuzz 10 -rands 4,13,30,45,52,60,66,72,80,95
  random: 4,13,30,45,52,60,66,72,80,95
  input: pred append i:list A, i:list A, o:list A.
         append [] L L.
         append [X|XS] L [X|R] :- append XS L R.
  ast:
    pred append (pred i:(list A), i:(list A), o:(list A))
    clause (append [] L L)
    clause (:- (append (:: X XS) L (:: X R)) (append XS L R))
  
  fuzzed input #1: pred append i:list A, i:list A, o:list A.
                   append [] L L.
                   append [X|XS] L [X|R] :- append XS L R.
  ast:
    pred append (pred i:(list A), i:(list A), o:(list A))
    clause (append [] L L)
    clause (:- (append (:: X XS) L (:: X R)) (append XS L R))
  measure: precision 100.0% (33/33) recall 100.0% (33/33) F1 100.0%
  
  fuzzed input #2: pred append i list A, i:list A, o:list A.
  error:                                 ^^^^^^^^  ^^^^^^^^  recovered syntax error
                   append [] L L.
                   append [X|XS] L [X|R] :- append XS L R.
  ast:
    pred append (pred i:(i list A), i:Err«i:list A», i:Err«o:list A»)
    clause (append [] L L)
    clause (:- (append (:: X XS) L (:: X R)) (append XS L R))
  note: not a subterm
  measure: precision 93.3% (28/30) recall 84.8% (28/33) F1 88.9%
  
  fuzzed input #3: pred append i:list A, i:list A; o:list A.
  error:                                         ^           recovered syntax error
                   append [] L L.
                   append [X|XS] L [X|R] :- append XS L R.
  ast:
    pred append (pred i:(list A), i:(list A Err«;»), o:(list A))
    clause (append [] L L)
    clause (:- (append (:: X XS) L (:: X R)) (append XS L R))
  note: not a subterm
  measure: precision 100.0% (33/33) recall 100.0% (33/33) F1 100.0%
  
  fuzzed input #4: pred append i:list A, i:list A, o:list A.
                   app;nd [] L L.
                   append [X|XS] L [X|R] :- append XS L R.
  ast:
    pred append (pred i:(list A), i:(list A), o:(list A))
    clause (; app (nd [] L L))
    clause (:- (append (:: X XS) L (:: X R)) (append XS L R))
  note: not a subterm
  measure: precision 88.6% (31/35) recall 93.9% (31/33) F1 91.2%
  
  fuzzed input #5: pred append i:list A, i:list A, o:list A.
                   append []   L.
                   append [X|XS] L [X|R] :- append XS L R.
  ast:
    pred append (pred i:(list A), i:(list A), o:(list A))
    clause (append [] L)
    clause (:- (append (:: X XS) L (:: X R)) (append XS L R))
  note: not a subterm
  measure: precision 100.0% (32/32) recall 100.0% (32/32) F1 100.0%
  
  fuzzed input #6: pred append i:list A, i:list A, o:list A.
                   append [] L L.
                   app;nd [X|XS] L [X|R] :- append XS L R.
  ast:
    pred append (pred i:(list A), i:(list A), o:(list A))
    clause (append [] L L)
    clause (:- (; app (nd (:: X XS) L (:: X R))) (append XS L R))
  note: not a subterm
  measure: precision 88.6% (31/35) recall 93.9% (31/33) F1 91.2%
  
  fuzzed input #7: pred append i:list A, i:list A, o:list A.
                   append [] L L.
                   append [X;XS] L [X|R] :- append XS L R.
  ast:
    pred append (pred i:(list A), i:(list A), o:(list A))
    clause (append [] L L)
    clause (:- (append (:: (; X XS) []) L (:: X R)) (append XS L R))
  note: not a subterm
  measure: precision 91.4% (32/35) recall 97.0% (32/33) F1 94.1%
  
  fuzzed input #8: pred append i:list A, i:list A, o:list A.
                   append [] L L.
                   append [X|XS] L;[X|R] :- append XS L R.
  ast:
    pred append (pred i:(list A), i:(list A), o:(list A))
    clause (append [] L L)
    clause (:- (; (append (:: X XS) L) (:: X R)) (append XS L R))
  note: not a subterm
  measure: precision 94.1% (32/34) recall 97.0% (32/33) F1 95.5%
  
  fuzzed input #9: pred append i:list A, i:list A, o:list A.
                   append [] L L.
                   append [X|XS] L [X|R] :$ append XS L R.
  error:                                 ^^                recovered syntax error
  error: unexpected character $ lexical error
  ast:
    pred append (pred i:(list A), i:(list A), o:(list A))
    clause (append [] L L)
    clause (append (:: X XS) L (:: X R) Err«:» Err«$» append XS L R)
  note: not a subterm
  measure: precision 96.7% (29/30) recall 87.9% (29/33) F1 92.1%
  
  fuzzed input #10: pred append i:list A, i:list A, o:list A.
                    append [] L L.
                    append [X|XS] L [X|R] :- append XS L R$
  error: line 4, column 0: completed with .
  ast:
    pred append (pred i:(list A), i:(list A), o:(list A))
    clause (append [] L L)
    clause (:- (append (:: X XS) L (:: X R)) (append XS L R$))
  note: not a subterm
  measure: precision 97.0% (32/33) recall 97.0% (32/33) F1 97.0%
  
