#lang info

(define collection 'multi)
(define deps '("base" "dover-lib"))
(define implies '("dover-lib"))
(define build-deps '("scribble-lib" "racket-doc"))
(define pkg-desc "Check Scribble documentation coverage for Racket packages")
(define version "0.1")
(define pkg-authors '("Joel Dueck"))
(define license '(Apache-2.0 OR MIT))
