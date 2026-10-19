#lang racket/base

;; The %-prefixed bindings get their public names elsewhere
(provide make-widget widget-size %frob %color %gadget)

(define (make-widget) 'widget)
(define (widget-size w) 1)
(define (%frob w) w)
(define (%color w) 'red)
(define (%gadget) 'gadget)
