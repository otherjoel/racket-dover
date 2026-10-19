#lang racket/base

;; Bindings re-exported under other names: rename-out, prefix-in, and a module that exports a
;; binding under two names. See fixtures/dover-fixture-renames.

(module+ test
  (require racket/list
           rackunit
           "fixture.rkt")

  (define pkg "dover-fixture-renames")
  (define (in-pkg sub) (if sub (string-append pkg "/" sub) pkg))

  ;; Each unreachable-docs warning as (module id documented-as use-source)
  (define (unreachable-warnings report)
    (sort (for/list ([w (in-list (hash-ref report 'warnings))]
                     #:when (equal? (hash-ref w 'type) "unreachable_docs"))
            (list (hash-ref w 'module) (hash-ref w 'id) (hash-ref w 'documented_as)
                  (hash-ref w 'use_source)))
          string<? #:key (λ (w) (format "~s" w))))

  (define impl (in-pkg "private/impl"))
  (define api (in-pkg "private/api"))

  (call-with-fixture
   pkg
   (λ (dir)
     (define before (dover-check pkg))

     ;; main exports make-widget as build-widget too. The binding is documented, since
     ;; make-widget connects to its docs, whatever order the names come in.
     (check-equal? (hash-ref (hash-ref before 'scored) 'documented) 5)
     (check-equal? (hash-ref (hash-ref before 'scored) 'total) 5)

     (check-equal?
      (unreachable-warnings before)
      (sort
       (list
        ;; Other names for a binding defined under the documented name: #:use-sources fixes it
        (list (in-pkg #f) "build-widget" "make-widget" impl)
        (list (in-pkg "ren") "new-widget" "make-widget" impl)
        (list (in-pkg "pre") "w:widget-size" "widget-size" impl)
        ;; Renamed once, in private/api: #:use-sources with that module fixes it
        (list (in-pkg "lite") "gadget" "gadget" api)
        ;; Renamed in each public module: no #:use-sources can fix it
        (list (in-pkg "lite") "frob" "frob" 'null)
        ;; Exported under a name the docs don't use
        (list (in-pkg "alt") "colour" "widget-color" 'null))
       string<? #:key (λ (w) (format "~s" w))))

     ;; Following the #:use-sources advice fixes every warning it was given for, and no others
     (replace-fixture-docs! pkg dir "scribblings/fixture.scrbl"
                            "dover-fixture-renames-use-sources.scrbl")
     (define after (dover-check pkg))
     (check-equal? (unreachable-warnings after)
                   (list (list (in-pkg "alt") "colour" "widget-color" 'null)
                         (list (in-pkg "lite") "frob" "frob" 'null))))))
