#lang racket/base

(require "base.rkt")
(provide (all-from-out "base.rkt")
         tally
         with-counter)

(define (tally pred lst)
  (for/sum ([v (in-list lst)])
    (if (pred v) 1 0)))

(define-syntax-rule (with-counter (c) body ...)
  (let ([c (make-counter)])
    body ...
    (counter-value c)))
