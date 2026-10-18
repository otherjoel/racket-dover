#lang racket/base

(require "private/coverage.rkt")

(provide (struct-out binding)
         (struct-out module-coverage)
         (struct-out coverage-report)
         package-modules
         module-bindings
         binding-doc-status
         check-coverage
         module-coverage-total
         coverage-ratio)
