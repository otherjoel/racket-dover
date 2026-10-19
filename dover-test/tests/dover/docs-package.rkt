#lang racket/base

;; Config in the info.rkt of the package that has the docs. See fixtures/dover-fixture-split-lib
;; and fixtures/dover-fixture-split-doc.

(module+ test
  (require rackunit
           "fixture.rkt")

  (define lib "dover-fixture-split-lib")
  (define docs "dover-fixture-split-doc")

  (call-with-fixtures
   (list lib docs)
   (λ (_lib-dir _docs-dir)
     (define report (dover-check lib))
     (define scored (hash-ref report 'scored))

     (check-equal? (hash-ref report 'config_packages) (list lib docs))
     ;; dover-ignore from both packages; dover-consider-private and the dover-never-ignore entry
     ;; for the lib's module from the docs package; not the docs package's own helper module
     (check-equal? (for/list ([m (in-list (hash-ref scored 'modules))])
                     (list (hash-ref m 'module)
                           (map (λ (b) (hash-ref b 'id)) (hash-ref m 'missing))))
                   '(("dover-fixture-split" ("missing"))
                     ("dover-fixture-split/private/kept" ("kept"))))
     (check-equal? (hash-ref scored 'documented) 1)
     (check-equal? (hash-ref scored 'total) 3)
     ;; dover-min-coverage from the docs package
     (check-equal? (dover-exit-status lib) 1))))
