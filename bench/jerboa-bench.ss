;;; bench/jerboa-bench.ss
;;; Copyright 2026 Cisco Systems, Inc.
;;;
;;; Licensed under the Apache License, Version 2.0 (the "License");
;;; you may not use this file except in compliance with the License.
;;; You may obtain a copy of the License at
;;;
;;; http://www.apache.org/licenses/LICENSE-2.0
;;;
;;; Unless required by applicable law or agreed to in writing, software
;;; distributed under the License is distributed on an "AS IS" BASIS,
;;; WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
;;; See the License for the specific language governing permissions and
;;; limitations under the License.

;;; Jerboa-oriented microbenchmark set for Chez Scheme.
;;;
;;; Focus: the Chez primitives that Jerboa's prelude funnels user code
;;; through. Each bench reports median wall-clock ms over REPS runs of a
;;; tight loop of ITERS iterations. Run:
;;;
;;;   scheme --script bench/jerboa-bench.ss
;;;
;;; or, for a quick pass:
;;;
;;;   scheme --script bench/jerboa-bench.ss fast

(define fast? (member "fast" (command-line-arguments)))

(define ITERS (if fast? 200000 2000000))
(define REPS  (if fast? 3 5))

;;; --- timing helpers ---

(define (now-ms)
  (let ([t (current-time 'time-monotonic)])
    (+ (* 1000.0 (time-second t))
       (/ (time-nanosecond t) 1.0e6))))

(define (time-once thunk)
  (let ([t0 (now-ms)])
    (thunk)
    (- (now-ms) t0)))

(define (median xs)
  (let* ([sorted (list-sort < xs)]
         [n (length sorted)])
    (list-ref sorted (fxdiv n 2))))

(define (bench name thunk)
  (collect (collect-maximum-generation))
  (thunk)                                  ; warmup
  (let loop ([i REPS] [acc '()])
    (if (fx= i 0)
        (let ([med (median acc)])
          (printf "bench: ~24a  ~10d iters   ~8,2F ms   (~a ns/iter)\n"
                  name ITERS med
                  (exact (round (* 1.0e6 (/ med ITERS))))))
        (loop (fx- i 1) (cons (time-once thunk) acc)))))

;;; --- populate some state ---

(define eq-ht (make-eq-hashtable))
(define eqv-ht (make-eqv-hashtable))
(define sym-ht (make-hashtable symbol-hash eq?))
(define equal-ht (make-hashtable string-hash string=?))

(do ([i 0 (fx+ i 1)]) ((fx= i 1024))
  (hashtable-set! eq-ht i (fx* i 2))
  (hashtable-set! eqv-ht i (fx* i 2))
  (hashtable-set! sym-ht (string->symbol (number->string i)) (fx* i 2))
  (hashtable-set! equal-ht (number->string i) (fx* i 2)))

;;; --- hashtable benches ---

(bench "eq-ht ref"
       (lambda ()
         (let loop ([i ITERS])
           (unless (fx= i 0)
             (hashtable-ref eq-ht (fxand i 1023) #f)
             (loop (fx- i 1))))))

(bench "eqv-ht ref"
       (lambda ()
         (let loop ([i ITERS])
           (unless (fx= i 0)
             (hashtable-ref eqv-ht (fxand i 1023) #f)
             (loop (fx- i 1))))))

(bench "symbol-ht ref"
       (lambda ()
         (let ([k 'a])
           (hashtable-set! sym-ht k 1)
           (let loop ([i ITERS])
             (unless (fx= i 0)
               (hashtable-ref sym-ht k #f)
               (loop (fx- i 1)))))))

(bench "equal-ht ref"
       (lambda ()
         (let ([k "512"])
           (let loop ([i ITERS])
             (unless (fx= i 0)
               (hashtable-ref equal-ht k #f)
               (loop (fx- i 1)))))))

(bench "eq-ht set!"
       (lambda ()
         (let loop ([i ITERS])
           (unless (fx= i 0)
             (hashtable-set! eq-ht (fxand i 1023) i)
             (loop (fx- i 1))))))

(bench "eq-ht contains?"
       (lambda ()
         (let loop ([i ITERS])
           (unless (fx= i 0)
             (hashtable-contains? eq-ht (fxand i 1023))
             (loop (fx- i 1))))))

(bench "hashtable-size"
       (lambda ()
         (let loop ([i ITERS])
           (unless (fx= i 0)
             (hashtable-size eq-ht)
             (hashtable-size eqv-ht)
             (hashtable-size equal-ht)
             (loop (fx- i 1))))))

(bench "hashtable-weak?"
       (lambda ()
         (let loop ([i ITERS])
           (unless (fx= i 0)
             (hashtable-weak? eq-ht)
             (hashtable-weak? eqv-ht)
             (hashtable-weak? equal-ht)
             (loop (fx- i 1))))))

(bench "hashtable-hash-function"
       (lambda ()
         (let loop ([i ITERS])
           (unless (fx= i 0)
             (hashtable-hash-function eq-ht)
             (hashtable-hash-function eqv-ht)
             (hashtable-hash-function equal-ht)
             (loop (fx- i 1))))))

;;; --- sealed record predicate + field access ---
;;; Models Jerboa defstruct + accessor.

(define-record-type bench-point
  (fields (immutable x) (immutable y))
  (sealed #t)
  (nongenerative #{bench-point jerboa-bench-2026-0}))

(define-record-type bench-circle
  (fields (immutable cx) (immutable cy) (immutable r))
  (sealed #t)
  (nongenerative #{bench-circle jerboa-bench-2026-1}))

(define p (make-bench-point 3 4))
(define c (make-bench-circle 0 0 5))

(bench "record predicate (pos)"
       (lambda ()
         (let loop ([i ITERS])
           (unless (fx= i 0)
             (bench-point? p)
             (loop (fx- i 1))))))

(bench "record predicate (neg)"
       (lambda ()
         (let loop ([i ITERS])
           (unless (fx= i 0)
             (bench-point? c)
             (loop (fx- i 1))))))

(bench "record field access"
       (lambda ()
         (let loop ([i ITERS] [s 0])
           (if (fx= i 0)
               s
               (loop (fx- i 1) (fx+ s (bench-point-x p)))))))

;;; --- iteration: named let over range (Jerboa for/fold equivalent) ---

(bench "fx loop fold"
       (lambda ()
         (let loop ([i ITERS] [s 0])
           (if (fx= i 0)
               s
               (loop (fx- i 1) (fx+ s i))))))

;;; --- list ops ---

(define big-list (let loop ([i 1024] [acc '()])
                   (if (fx= i 0) acc (loop (fx- i 1) (cons i acc)))))

(bench "list map+length"
       (lambda ()
         (let loop ([i (fxdiv ITERS 1024)])
           (unless (fx= i 0)
             (length (map (lambda (x) (fx+ x 1)) big-list))
             (loop (fx- i 1))))))

;;; --- string ops (Jerboa's str auto-coercion path) ---

(bench "number->string + append"
       (lambda ()
         (let loop ([i (fxdiv ITERS 10)])
           (unless (fx= i 0)
             (string-append "n=" (number->string i) "!")
             (loop (fx- i 1))))))

(printf "\ndone.\n")
