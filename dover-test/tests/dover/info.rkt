#lang info

;; Each directory in fixtures/ is a package that a test installs, from a temporary copy
(define compile-omit-paths '("fixtures"))
(define test-omit-paths '("fixtures" "fixture.rkt"))
