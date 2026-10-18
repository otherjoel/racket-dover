#lang racket/base

(require "private/coverage.rkt")

(provide (struct-out binding)
         (struct-out exporter)
         (struct-out module-coverage)
         (struct-out doc-warning)
         (struct-out unreachable-docs-warning)
         (struct-out export-claim-warning)
         (struct-out coverage-report)
         package-modules
         binding-documented?
         check-coverage
         module-coverage-total
         coverage-ratio)
