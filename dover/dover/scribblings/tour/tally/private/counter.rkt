#lang racket/base

(provide counter? make-counter counter-add! counter-value)

(struct counter ([n #:mutable]))

(define (make-counter)
  (counter 0))

(define (counter-add! c [k 1])
  (set-counter-n! c (+ (counter-n c) k)))

(define (counter-value c)
  (counter-n c))
