#lang info

(define collection "dover-fixture-split-doc")
(define deps '("base"))
(define build-deps '("dover-fixture-split-lib" "scribble-lib" "racket-doc"))
(define scribblings '(("scribblings/split.scrbl")))

(define dover-ignore '((dover-fixture-split docs-ignored)))
(define dover-consider-private '(dover-fixture-split/internal))
;; Only the entries for the checked package's modules count
(define dover-never-ignore '(dover-fixture-split/private/kept dover-fixture-split-doc/helper))
(define dover-modules '(dover-fixture-split-doc/helper))
(define dover-min-coverage 100)
