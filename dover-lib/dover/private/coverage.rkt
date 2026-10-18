#lang racket/base

(require pkg/lib
         pkg/path
         racket/format
         racket/list
         racket/match
         racket/path
         racket/promise
         racket/string
         scribble/xref
         setup/collects
         setup/getinfo
         setup/xref)

(provide (struct-out binding)
         (struct-out module-coverage)
         (struct-out coverage-report)
         normalize-module-path
         module<?
         package-modules
         module-bindings
         binding-doc-status
         binding-documented-via
         check-coverage
         module-coverage-total
         coverage-totals
         coverage-ratio)

;;================================================
;; Data

;; module    : the module being checked that exports the binding
;; id        : the name it is exported under
;; kind      : 'value or 'syntax
;; source-*  : where the binding is originally defined, and the package that module belongs to
;;             (#f for Racket's main collections)
;; via       : (listof (cons module-path symbol)), the modules and names the binding passes
;;             through between module and source-module
(struct binding (module id kind source-module source-id source-pkg via) #:transparent)

(struct module-coverage (module documented unreachable missing) #:transparent)

;; scored   : module-coverage for bindings defined in the packages being checked
;; unscored : module-coverage for bindings re-exported from other packages
;; errors   : (listof (cons module-path string)) for modules that could not be loaded
(struct coverage-report (scored unscored errors) #:transparent)

;;================================================
;; Module paths

;; (lib "x/main.rkt") -> 'x,  (lib "x/y.rkt") -> 'x/y,  'x/main -> 'x
;; Only a one-segment path can drop "/main": 'x/y means x/y.rkt, not x/y/main.rkt.
(define (normalize-module-path mp)
  (define (trim-main s)
    (match (regexp-match #rx"^([^/]+)/main$" s)
      [(list _ coll) coll]
      [_ s]))
  (match mp
    [(list 'lib (? string? str))
     (string->symbol (trim-main (regexp-replace #rx"[.][^./]*$" str "")))]
    [(? symbol? s)
     (string->symbol (trim-main (symbol->string s)))]
    [(list 'submod base subs ...)
     `(submod ,(normalize-module-path base) ,@subs)]
    [_ mp]))

;; 'x < 'x/a < '(submod x b) < 'x/c < 'y,  and 'x/y < 'x-z/y
(define (module-sort-key mod)
  (match mod
    [(list 'submod base subs ...)
     (append (module-sort-key base) (map symbol->string subs))]
    [_ (string-split (~a mod) "/")]))

(define (segments<? a b)
  (cond
    [(null? b) #f]
    [(null? a) #t]
    [(string=? (car a) (car b)) (segments<? (cdr a) (cdr b))]
    [else (string<? (car a) (car b))]))

(define (module<? a b)
  (segments<? (module-sort-key a) (module-sort-key b)))

(define pkg-cache (make-hash))
(define package-by-name (make-hash))
(define module-path-by-name (make-hash))

;; Both of these are called for every binding, so they're memoized on the resolved name.
(define (module-package mod)
  (define mpi (if (module-path-index? mod) mod (module-path-index-join mod #f)))
  (with-handlers ([exn:fail? (λ (_e) #f)])
    (define name (resolved-module-path-name (module-path-index-resolve mpi #t)))
    (hash-ref! package-by-name name
               (λ ()
                 (match name
                   [(cons (? path? p) _submods) (path->pkg p #:cache pkg-cache)]
                   [(? path? p) (path->pkg p #:cache pkg-cache)]
                   [_ #f])))))

(define (mpi->module-path mpi)
  (define name (resolved-module-path-name (module-path-index-resolve mpi)))
  (hash-ref! module-path-by-name name
             (λ ()
               (match name
                 [(list* (? path? p) submods)
                  `(submod ,(normalize-module-path (path->module-path p)) ,@submods)]
                 [(? path? p) (normalize-module-path (path->module-path p))]
                 [name name]))))

;;================================================
;; Finding a package's modules

;; Directories under these names are never searched. "private" is skipped unless
;; #:include-private? is true.
(define skipped-dirs '("compiled" "scribblings"))

(define (lang-reader? p)
  (regexp-match? #rx"[/\\\\]lang[/\\\\]reader[.]rkt$" (path->string p)))

;; Returns the paths that an info.rkt in dir excludes from compilation, or 'all.
(define (compile-omitted dir)
  (define info (get-info/full dir))
  (match (if info (info 'compile-omit-paths (λ () '())) '())
    ['all 'all]
    [(? list? ps) (for/list ([p (in-list ps)]
                             #:when (path-string? p))
                    (simple-form-path (build-path dir p)))]
    [_ '()]))

;; Returns the modules in pkg's collections, sorted so that a module comes before its
;; submodules and the modules nested under it. Skips info.rkt, lang/reader.rkt, files that are
;; not in any collection, and paths excluded by `compile-omit-paths`, since `raco setup` doesn't
;; compile those.
(define (package-modules pkg #:include-private? [include-private? #f])
  (define root
    (or (pkg-directory pkg)
        (raise-arguments-error 'package-modules "package is not installed" "package" pkg)))
  (define (skip-dir? name)
    (or (member name skipped-dirs)
        (string-prefix? name ".")
        (and (not include-private?) (equal? name "private"))))
  (define (module-file? p name)
    (and (path-has-extension? p #".rkt")
         (not (equal? name "info.rkt"))
         (not (lang-reader? p))))
  (define (walk dir omitted)
    (define here (compile-omitted dir))
    (cond
      [(eq? here 'all) '()]
      [else
       (define omitted* (append here omitted))
       (for*/fold ([mods '()])
                  ([p (in-list (directory-list dir #:build? #t))]
                   #:unless (member (simple-form-path p) omitted*))
         (define name (path->string (file-name-from-path p)))
         (cond
           [(directory-exists? p)
            (if (skip-dir? name) mods (append (walk p omitted*) mods))]
           [(module-file? p name)
            (match (path->module-path (simple-form-path p))
              [(? pair? mp) (cons (normalize-module-path mp) mods)]
              [_ mods])]
           [else mods]))]))
  (sort (remove-duplicates (walk (simple-form-path root) '())) module<?))

;;================================================
;; Getting bindings

(define (phase-0-exports lst)
  (cond [(assv 0 lst) => cdr]
        [else '()]))

(define (resolved->module-path r)
  (match (resolved-module-path-name r)
    [(list* base submods) `(submod ,(if (symbol? base) `(quote ,base) base) ,@submods)]
    [(? symbol? s) `(quote ,s)]
    [p p]))

;; Maps resolved module paths to their phase-0 exports for the duration of a check
(define current-export-cache (make-parameter #f))

;; Module path indexes can come from the module declaration cache already resolved, in which case
;; resolving with load? = #t doesn't declare the module in the current namespace. So declare it
;; explicitly.
(define (phase-0-export-table mpi)
  (define r (module-path-index-resolve mpi))
  (define (compute)
    (define mp (resolved->module-path r))
    (module-declared? mp #t)
    (define-values (vars forms) (module->exports mp))
    (append (phase-0-exports vars) (phase-0-exports forms)))
  (define cache (current-export-cache))
  (if cache (hash-ref! cache r compute) (compute)))

;; Returns the origins that mpi records for its export `name`, or #f if it doesn't export `name`.
(define (export-origins mpi name)
  (cond [(assq name (phase-0-export-table mpi)) => cadr]
        [else #f]))

;; Export origins are relative to the exporting module (e.g. "html.rkt") and would otherwise
;; resolve against the current directory. Same as `module-path-index-rejoin` in scribble/search.
(define (module-path-index-rejoin mpi rel-to)
  (define-values (name base) (module-path-index-split mpi))
  (cond
    [(not name) rel-to]
    [(not base) mpi]
    [else (module-path-index-join name (module-path-index-rejoin base rel-to))]))

;; In an origin of the form (list mpi phase import-sym phase), import-sym is usually the name the
;; origin module exports. But when a binding is imported more than once, Racket records the local
;; (e.g. prefixed) name instead, which the origin module doesn't export. So check each candidate.
;; Returns (cons mpi name) for the module the binding was imported from.
(define (pick-origin id origins rel-to)
  (define candidates
    (for*/list ([origin (in-list origins)]
                [name (in-list (match origin
                                 [(list _ _ import-sym _) (remove-duplicates (list import-sym id))]
                                 [_ (list id)]))])
      (cons (module-path-index-rejoin (if (pair? origin) (car origin) origin) rel-to) name)))
  (or (for/first ([c (in-list candidates)]
                  #:when (export-origins (car c) (cdr c)))
        c)
      (car candidates)))

;; Follows a re-exported binding back to the module that defines it. Returns the list of
;; (cons mpi name) hops after the exporting module; the last hop is the definition.
(define (reexport-hops id origins rel-to)
  (let loop ([id id] [origins origins] [rel-to rel-to] [fuel 100])
    (cond
      [(or (null? origins) (zero? fuel)) '()]
      [else
       (match-define (and hop (cons mpi name)) (pick-origin id origins rel-to))
       (cons hop (loop name (or (export-origins mpi name) '()) mpi (sub1 fuel)))])))

;; Declares (but does not instantiate) mod in the current namespace and returns the bindings it
;; exports at phase 0.
(define (module-bindings mod)
  (unless (module-declared? mod #t)
    (raise-arguments-error 'module-bindings "module not found" "module" mod))
  (define-values (vars forms) (module->exports mod))
  (define mod-pkg (module-package mod))
  (define mod-mpi (module-path-index-join mod #f))
  (define (exports->bindings exports kind)
    (for/list ([export (in-list (phase-0-exports exports))])
      (match-define (list id origins) export)
      (match (reexport-hops id origins mod-mpi)
        ['() (binding mod id kind mod id mod-pkg '())]
        [hops
         (match-define (cons def-mpi def-id) (last hops))
         (binding mod id kind (mpi->module-path def-mpi) def-id (module-package def-mpi)
                  (for/list ([hop (in-list (drop-right hops 1))])
                    (cons (mpi->module-path (car hop)) (cdr hop))))])))
  (append (exports->bindings vars 'value)
          (exports->bindings forms 'syntax)))

;;================================================
;; Checking Scribble docs

(define collections-xref (delay (load-collections-xref)))

(define (has-definition-tag? mod id)
  (with-handlers ([exn:fail? (λ (_e) #f)])
    (and (xref-binding->definition-tag (force collections-xref) (list mod id) #f) #t)))

;; Returns the first module, after the exporting module, through which Scribble can find
;; documentation for b, or #f.
(define (binding-documented-via b)
  (for/first ([hop (in-list (append (binding-via b)
                                    (list (cons (binding-source-module b) (binding-source-id b)))))]
              #:when (has-definition-tag? (car hop) (cdr hop)))
    (car hop)))

;; 'unreachable = documented through a module the binding passes through on the way from its
;; definition, but Scribble can't get there from the module that exports it
(define (binding-doc-status b)
  (cond
    [(has-definition-tag? (binding-module b) (binding-id b)) 'documented]
    [(binding-documented-via b) 'unreachable]
    [else 'missing]))

;; Each element of ignore is a module path (ignore every binding exported from or defined in that
;; module) or a list of a module path and ids (ignore only those ids).
(define (ignored? b ignore)
  (match-define (binding mod id _ src-mod src-id _ _) b)
  (for/or ([spec (in-list ignore)])
    (match spec
      [(list ignore-mod ids ...)
       (define m (normalize-module-path ignore-mod))
       (or (and (equal? m mod) (memq id ids) #t)
           (and (equal? m src-mod) (memq src-id ids) #t))]
      [ignore-mod
       (define m (normalize-module-path ignore-mod))
       (or (equal? m mod) (equal? m src-mod))])))

(define (bindings->coverage bindings)
  (for/list ([group (in-list (sort (group-by binding-module bindings) module<?
                                   #:key (λ (g) (binding-module (car g)))))])
    (define statuses (map binding-doc-status group))
    (define (with-status s)
      (for/list ([b (in-list group)]
                 [st (in-list statuses)]
                 #:when (eq? st s))
        b))
    (module-coverage (binding-module (car group))
                     (with-status 'documented)
                     (with-status 'unreachable)
                     (with-status 'missing))))

;; Checks the bindings exported from mods. A binding defined in one of pkgs counts toward the
;; score; one re-exported from another package is reported but not scored; one from Racket's
;; main collections is skipped. When several modules export the same binding, it is reported
;; under the first of mods that exports it.
(define (check-coverage mods #:packages pkgs #:ignore [ignore '()])
  (define-values (bindings errors)
    (parameterize ([current-namespace (make-base-empty-namespace)]
                   [current-export-cache (make-hash)])
      (for/fold ([bindings '()]
                 [errors '()]
                 #:result (values (reverse bindings) (reverse errors)))
                ([mod (in-list mods)])
        (with-handlers ([exn:fail? (λ (e) (values bindings
                                                  (cons (cons mod (exn-message e)) errors)))])
          (values (append (reverse (module-bindings mod)) bindings) errors)))))
  (define kept
    (remove-duplicates
     (for/list ([b (in-list bindings)]
                #:when (binding-source-pkg b)
                #:unless (ignored? b ignore))
       b)
     #:key (λ (b) (cons (binding-source-module b) (binding-source-id b)))))
  (define-values (scored unscored)
    (partition (λ (b) (member (binding-source-pkg b) pkgs)) kept))
  (coverage-report (bindings->coverage scored)
                   (bindings->coverage unscored)
                   errors))

(define (module-coverage-total mc)
  (+ (length (module-coverage-documented mc))
     (length (module-coverage-unreachable mc))
     (length (module-coverage-missing mc))))

;; Returns the number of documented bindings and the total number of bindings.
(define (coverage-totals mcs)
  (values (for/sum ([mc (in-list mcs)]) (length (module-coverage-documented mc)))
          (for/sum ([mc (in-list mcs)]) (module-coverage-total mc))))

;; Returns a number from 0 to 1, or #f if there are no bindings.
(define (coverage-ratio mcs)
  (define-values (documented total) (coverage-totals mcs))
  (and (positive? total) (/ documented total)))

(module+ test
  (require rackunit)

  (check-equal? (normalize-module-path '(lib "dover/main.rkt")) 'dover)
  (check-equal? (normalize-module-path '(lib "dover/x.rkt")) 'dover/x)
  (check-equal? (normalize-module-path 'dover/main) 'dover)
  (check-equal? (normalize-module-path 'dover/domain) 'dover/domain)
  (check-equal? (normalize-module-path '(lib "scribble/doc/main.rkt")) 'scribble/doc/main)
  (check-equal? (normalize-module-path '(submod (lib "a/main.rkt") b)) '(submod a b))

  (check-equal? (sort '(b a/c (submod a x) a a-z/b) module<?)
                '(a a/c (submod a x) a-z/b b))

  (define take-binding (binding 'racket/list 'take 'value 'racket/list 'take #f '()))
  (check-eq? (binding-doc-status take-binding) 'documented)
  (check-eq? (binding-doc-status (struct-copy binding take-binding [id 'no-such-thing]
                                              [source-id 'no-such-thing]))
             'missing)

  (check-true (ignored? take-binding '(racket/list)))
  (check-true (ignored? take-binding '((racket/list take drop))))
  (check-false (ignored? take-binding '((racket/list drop))))
  (check-false (ignored? take-binding '(racket/base)))

  (define list-bindings
    (parameterize ([current-namespace (make-base-empty-namespace)])
      (module-bindings 'racket/list)))
  (check-not-false (findf (λ (b) (eq? (binding-id b) 'take)) list-bindings))

  ;; Racket's main collections are skipped
  (check-equal? (check-coverage '(racket/list) #:packages '("base"))
                (coverage-report '() '() '()))

  (check-equal? (coverage-ratio (list (module-coverage 'a (list take-binding) '() '())
                                      (module-coverage 'b '() '() (list take-binding))))
                1/2)
  (check-false (coverage-ratio '())))
