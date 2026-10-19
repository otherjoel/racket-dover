#lang racket/base

(provide widget missing own-ignored docs-ignored)

(define (widget) 'widget)
(define (missing) 'missing)
(define (own-ignored) 'own-ignored)
(define (docs-ignored) 'docs-ignored)
