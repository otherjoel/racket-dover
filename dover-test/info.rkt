#lang info

(define collection 'multi)
;; The fixture packages build their docs with scribble-lib and racket-doc
(define deps '("base" "dover-lib" "rackunit-lib" "scribble-lib" "racket-doc"))
(define pkg-desc "Tests for \"dover\"")
(define version "0.1")
(define pkg-authors '("Joel Dueck"))
(define license '(Apache-2.0 OR MIT))
