#lang racket/base

(require pkg/lib
         pkg/path
         racket/format
         racket/list
         racket/match
         racket/path
         racket/promise
         racket/string
         scribble/manual-struct
         scribble/core
         scribble/xref
         setup/collects
         setup/getinfo
         setup/xref)

(provide (struct-out binding)
         (struct-out exporter)
         (struct-out module-coverage)
         (struct-out doc-warning)
         (struct-out unreachable-docs-warning)
         (struct-out export-claim-warning)
         (struct-out coverage-report)
         normalize-module-path
         module<?
         package-modules
         binding-documented?
         module-has-defmodule?
         check-coverage
         module-coverage-total
         coverage-totals
         coverage-ratio)

;;================================================
;; Data

;; A checked module's export of a binding. A module that exports a binding under more than one name
;; has an exporter for each name.
;; module      : the module
;; id          : the name it exports the binding under
;; via         : (listof (cons module-path symbol)), the modules and names the binding passes
;;               through between module and the definition
;; documented? : whether the binding, as exported by module under id, connects to its docs
(struct exporter (module id via documented?) #:transparent)

;; A binding, identified by where it is defined.
;; module, id  : the module it is reported under and its name there
;; kind        : 'value or 'syntax
;; source-*    : where it is originally defined, and the package that module belongs to
;; exporters   : (listof exporter), every checked module that exports it
;; doc-modules : #f if Scribble can't find docs for it; otherwise the modules the docs say export
;;               it (from defmodule or declare-exporting)
(struct binding (module id kind source-module source-id source-pkg exporters doc-modules)
  #:transparent)

(struct module-coverage (module documented missing) #:transparent)

;; Documentation hygiene problems for a documented binding
(struct doc-warning (binding module) #:transparent)
;; The binding is documented, but as exported by module, which exports it, it doesn't connect to
;; its docs.
;; id         : the name module exports the binding under
;; doc-id     : the name the docs use for it
;; use-source : a module on the binding's re-export path from module that exports it as doc-id,
;;              so that adding it to #:use-sources connects this export; or #f if there's none
(struct unreachable-docs-warning doc-warning (id doc-id use-source) #:transparent)
;; The docs say module exports the binding, but it doesn't
(struct export-claim-warning doc-warning () #:transparent)

;; scored   : module-coverage for bindings defined in the packages being checked
;; unscored : module-coverage for bindings re-exported from other packages
;; warnings : (listof doc-warning) for scored bindings
;; errors   : (listof (cons module-path string)) for modules that could not be loaded
(struct coverage-report (scored unscored warnings errors) #:transparent)

(define (binding-documented? b)
  (and (binding-doc-modules b) #t))

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

;; One module's export of a binding, before exports of the same binding are combined
(struct raw-export (module id kind via source-module source-id source-pkg))

;; Declares (but does not instantiate) mod in the current namespace and returns the bindings it
;; exports at phase 0.
(define (module-exports mod)
  (unless (module-declared? mod #t)
    (raise-arguments-error 'module-exports "module not found" "module" mod))
  (define-values (vars forms) (module->exports mod))
  (define mod-pkg (module-package mod))
  (define mod-mpi (module-path-index-join mod #f))
  (define (exports->raw exports kind)
    (for/list ([export (in-list (phase-0-exports exports))])
      (match-define (list id origins) export)
      (match (reexport-hops id origins mod-mpi)
        ['() (raw-export mod id kind '() mod id mod-pkg)]
        [hops
         (match-define (cons def-mpi def-id) (last hops))
         (raw-export mod id kind
                     (for/list ([hop (in-list (drop-right hops 1))])
                       (cons (mpi->module-path (car hop)) (cdr hop)))
                     (mpi->module-path def-mpi) def-id (module-package def-mpi))])))
  (append (exports->raw vars 'value)
          (exports->raw forms 'syntax)))

;;================================================
;; Checking Scribble docs

(define collections-xref (delay (load-collections-xref)))

(define (definition-tag mod id)
  (with-handlers ([exn:fail? (λ (_e) #f)])
    (xref-binding->definition-tag (force collections-xref) (list mod id) #f)))

;; Returns the modules that the docs say export the binding, as found from mod.
(define (documented-exporting-modules mod id)
  (define entry (xref-tag->index-entry (force collections-xref) (definition-tag mod id)))
  (define desc (and entry (entry-desc entry)))
  (if (exported-index-desc? desc)
      (remove-duplicates (map normalize-module-path (exported-index-desc-from-libs desc)))
      '()))

;; True if the installed docs have a defmodule for mod. A defmodule declares a (mod-path "mod")
;; tag (unless it has #:link-target? #f); declare-exporting declares no tag.
(define (module-has-defmodule? mod)
  (define str (if (symbol? mod) (symbol->string mod) (~s mod)))
  (define-values (path _anchor)
    (xref-tag->path+anchor (force collections-xref) (list 'mod-path str)))
  (and path #t))

;; Each element of ignore is a module path (ignore every binding exported from or defined in that
;; module) or a list of a module path and ids (ignore only those ids).
(define (ignored? r ignore)
  (match-define (raw-export mod id _ _ src-mod src-id _) r)
  (for/or ([spec (in-list ignore)])
    (match spec
      [(list ignore-mod ids ...)
       (define m (normalize-module-path ignore-mod))
       (or (and (equal? m mod) (memq id ids) #t)
           (and (equal? m src-mod) (memq src-id ids) #t))]
      [ignore-mod
       (define m (normalize-module-path ignore-mod))
       (or (equal? m mod) (equal? m src-mod))])))

;;================================================
;; Choosing the module a binding is reported under

;; Returns the exporter nearest to the definition: the first checked module on a re-export path,
;; walking out from the definition. Ties go to the module that sorts first.
(define (nearest-exporter exporters source-module)
  (define exporter-mods (map exporter-module exporters))
  (define candidates
    (for/list ([e (in-list exporters)])
      (define outward
        (append (list source-module)
                (reverse (map car (exporter-via e)))
                (list (exporter-module e))))
      (for/first ([m (in-list outward)]
                  [distance (in-naturals)]
                  #:when (member m exporter-mods))
        (cons distance m))))
  (cdr (car (sort candidates
                  (λ (a b) (or (< (car a) (car b))
                               (and (= (car a) (car b)) (module<? (cdr a) (cdr b)))))))))

;; A documented binding goes under the first exporter its docs name; any other binding goes under
;; the exporter nearest its definition.
(define (report-module exporters source-module doc-modules)
  (define exporter-mods (map exporter-module exporters))
  (or (and doc-modules
           (for/first ([m (in-list doc-modules)] #:when (member m exporter-mods)) m))
      (nearest-exporter exporters source-module)))

;; A missing binding goes with its siblings, the documented bindings defined in the same module:
;; under the module that most of them are reported under, if it also exports the missing
;; binding. Ties go to the module that sorts first. Other missing bindings stay under the
;; exporter nearest their definition.
(define (place-with-siblings bindings)
  (define sibling-modules ; source module -> the modules its documented bindings are reported under
    (for/fold ([h (hash)]) ([b (in-list bindings)] #:when (binding-documented? b))
      (hash-update h (binding-source-module b) (λ (ms) (cons (binding-module b) ms)) '())))
  (for/list ([b (in-list bindings)])
    (define exporter-mods (map exporter-module (binding-exporters b)))
    (define counts
      (for/fold ([h (hash)])
                ([m (in-list (hash-ref sibling-modules (binding-source-module b) '()))]
                 #:when (member m exporter-mods))
        (hash-update h m add1 0)))
    (cond
      [(or (binding-documented? b) (hash-empty? counts)) b]
      [else
       (define mod
         (car (sort (hash-keys counts)
                    (λ (x y) (or (> (hash-ref counts x) (hash-ref counts y))
                                 (and (= (hash-ref counts x) (hash-ref counts y))
                                      (module<? x y)))))))
       (struct-copy binding b
                    [module mod]
                    [id (id-in-module (binding-exporters b) mod (binding-source-id b))])])))

;; The name that mod exports the binding under, when it has more than one: one that connects to the
;; docs, else the name it's defined under, else the first.
(define (id-in-module exporters mod source-id)
  (define es (filter (λ (e) (equal? (exporter-module e) mod)) exporters))
  (exporter-id (or (findf exporter-documented? es)
                   (findf (λ (e) (eq? (exporter-id e) source-id)) es)
                   (car es))))

;; Combines one binding's exports (all with the same definition) into a binding. Each name a
;; module exports it under is checked, since each can connect to the docs or not.
(define (raw-exports->binding rs)
  (match-define (raw-export _ _ kind _ src-mod src-id src-pkg) (car rs))
  (define exporters
    (for/list ([r (in-list (remove-duplicates rs #:key (λ (r) (cons (raw-export-module r)
                                                                    (raw-export-id r)))))])
      (exporter (raw-export-module r) (raw-export-id r) (raw-export-via r)
                (and (definition-tag (raw-export-module r) (raw-export-id r)) #t))))
  (define doc-modules
    (for/first ([e (in-list exporters)] #:when (exporter-documented? e))
      (documented-exporting-modules (exporter-module e) (exporter-id e))))
  (define mod (report-module exporters src-mod doc-modules))
  (binding mod (id-in-module exporters mod src-id) kind src-mod src-id src-pkg exporters
           doc-modules))

;; The name the docs use for a documented binding: the name in the definition tag that one of its
;; connecting exports finds, else that export's name.
(define (documented-id b)
  (define e (findf exporter-documented? (binding-exporters b)))
  (match (definition-tag (exporter-module e) (exporter-id e))
    [(list _ (list _ (? symbol? name))) name]
    [_ (exporter-id e)]))

;; A module on e's re-export path, working outward from the definition, that exports the binding
;; as doc-id; or #f if there's none.
(define (use-source-for b e doc-id)
  (for/first ([hop (in-list (cons (cons (binding-source-module b) (binding-source-id b))
                                  (reverse (exporter-via e))))]
              #:when (eq? (cdr hop) doc-id))
    (car hop)))

;; checked : hash whose keys are the modules that were checked successfully
(define (binding-warnings b checked)
  (cond
    [(not (binding-documented? b)) '()]
    [else
     (define exporter-mods (map exporter-module (binding-exporters b)))
     (define doc-id (documented-id b))
     (append
      (for/list ([e (in-list (binding-exporters b))]
                 #:unless (exporter-documented? e))
        (unreachable-docs-warning b (exporter-module e) (exporter-id e) doc-id
                                  (use-source-for b e doc-id)))
      (for/list ([m (in-list (binding-doc-modules b))]
                 #:when (hash-ref checked m #f)
                 #:unless (member m exporter-mods))
        (export-claim-warning b m)))]))

(define (bindings->coverage bindings)
  (for/list ([group (in-list (sort (group-by binding-module bindings) module<?
                                   #:key (λ (g) (binding-module (car g)))))])
    (define-values (documented missing) (partition binding-documented? group))
    (module-coverage (binding-module (car group)) documented missing)))

;; Checks the bindings exported from mods. A binding defined in one of pkgs counts toward the
;; score; one re-exported from another package is reported but not scored; one from Racket's
;; main collections is skipped.
(define (check-coverage mods #:packages pkgs #:ignore [ignore '()])
  (define-values (raws errors)
    (parameterize ([current-namespace (make-base-empty-namespace)]
                   [current-export-cache (make-hash)])
      (for/fold ([raws '()]
                 [errors '()]
                 #:result (values (reverse raws) (reverse errors)))
                ([mod (in-list mods)])
        (with-handlers ([exn:fail? (λ (e) (values raws
                                                  (cons (cons mod (exn-message e)) errors)))])
          (values (append (reverse (module-exports mod)) raws) errors)))))
  (define checked
    (for/hash ([mod (in-list mods)] #:unless (assoc mod errors))
      (values mod #t)))
  (define bindings
    (place-with-siblings
     (for/list ([rs (in-list (group-by (λ (r) (cons (raw-export-source-module r)
                                                    (raw-export-source-id r)))
                                       raws))]
                #:when (raw-export-source-pkg (car rs))
                #:unless (for/or ([r (in-list rs)]) (ignored? r ignore)))
       (raw-exports->binding rs))))
  (define-values (scored unscored)
    (partition (λ (b) (member (binding-source-pkg b) pkgs)) bindings))
  (coverage-report (bindings->coverage scored)
                   (bindings->coverage unscored)
                   (sort (append-map (λ (b) (binding-warnings b checked)) scored)
                         module<? #:key doc-warning-module)
                   errors))

(define (module-coverage-total mc)
  (+ (length (module-coverage-documented mc))
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

  (define (raw mod id #:source [src mod] #:source-id [src-id id])
    (raw-export mod id 'value '() src src-id "pkg"))
  (check-true (ignored? (raw 'racket/list 'take) '(racket/list)))
  (check-true (ignored? (raw 'racket/list 'take) '((racket/list take drop))))
  (check-false (ignored? (raw 'racket/list 'take) '((racket/list drop))))
  (check-true (ignored? (raw 'a 'x #:source 'b #:source-id 'y) '((b y))))
  (check-false (ignored? (raw 'racket/list 'take) '(racket/base)))

  (check-not-false (findf (λ (r) (eq? (raw-export-id r) 'take))
                          (parameterize ([current-namespace (make-base-empty-namespace)])
                            (module-exports 'racket/list))))

  ;; `first` is defined in racket/private/list-predicates, documented under racket/list
  (define first-exporters (list (exporter 'racket 'first '((racket/list . first)) #t)
                                (exporter 'racket/list 'first '() #t)))
  (check-equal? (documented-exporting-modules 'racket/list 'first) '(racket/list racket))
  (check-true (module-has-defmodule? 'racket/list))
  ;; Documented only through declare-exporting
  (check-false (module-has-defmodule? 'compiler/commands/test))
  (check-false (module-has-defmodule? 'no/such/module))
  (check-equal? (report-module first-exporters 'racket/private/list-predicates
                               '(racket/list racket))
                'racket/list)

  ;; Undocumented: the exporter nearest the definition wins, whatever the sort order.
  ;; m/private/impl defines foo; m/z re-exports it; m/a re-exports m/z.
  (define foo-exporters (list (exporter 'm/a 'foo '((m/z . foo)) #f)
                              (exporter 'm/z 'foo '() #f)))
  (check-equal? (nearest-exporter foo-exporters 'm/private/impl) 'm/z)
  (check-equal? (report-module foo-exporters 'm/private/impl #f) 'm/z)
  ;; A checked definition module is nearest of all
  (check-equal? (nearest-exporter (cons (exporter 'm/private/impl 'foo '() #f) foo-exporters)
                                  'm/private/impl)
                'm/private/impl)
  ;; Two modules at the same distance: sort order breaks the tie
  (check-equal? (nearest-exporter (list (exporter 'm/z 'foo '() #f) (exporter 'm/a 'foo '() #f))
                                  'm/private/impl)
                'm/a)

  ;; Missing bar goes with its documented siblings from m/private/impl under m/a, which exports
  ;; it too, rather than under m/z, the exporter nearest its definition. Missing baz has no
  ;; documented siblings, so it stays put.
  (define (impl-binding id mod doc-modules exporter-mods)
    (binding mod id 'value 'm/private/impl id "pkg"
             (for/list ([m (in-list exporter-mods)]) (exporter m id '() (and doc-modules #t)))
             doc-modules))
  (define placed
    (place-with-siblings
     (list (impl-binding 'foo 'm/a '(m/a) '(m/a m/z))
           (impl-binding 'qux 'm/a '(m/a) '(m/a))
           (impl-binding 'bar 'm/z #f '(m/a m/z))
           (impl-binding 'baz 'm/z #f '(m/b m/z))
           (binding 'm/z 'zap 'value 'm/private/other 'zap "pkg"
                    (list (exporter 'm/a 'zap '() #f) (exporter 'm/z 'zap '() #f))
                    #f))))
  (check-equal? (map (λ (b) (cons (binding-id b) (binding-module b))) placed)
                '((foo . m/a) (qux . m/a) (bar . m/a) (baz . m/z) (zap . m/z)))

  ;; Warnings: foo as exported by m/b doesn't connect to its docs, and the docs claim m/c exports
  ;; foo
  (define documented-foo
    (binding 'm/a 'foo 'value 'm/private/impl 'foo "pkg"
             (list (exporter 'm/a 'foo '() #t) (exporter 'm/b 'foo '() #f))
             '(m/a m/c)))
  (check-equal? (binding-warnings documented-foo (hash 'm/a #t 'm/b #t 'm/c #t))
                (list (unreachable-docs-warning documented-foo 'm/b 'foo 'foo 'm/private/impl)
                      (export-claim-warning documented-foo 'm/c)))
  ;; Claims about modules that weren't checked are left alone
  (check-equal? (binding-warnings documented-foo (hash 'm/a #t 'm/b #t))
                (list (unreachable-docs-warning documented-foo 'm/b 'foo 'foo 'm/private/impl)))

  ;; Renames. m/private/impl defines %frob; the docs document it as frob, through m/a.
  (define (frob-warnings . exporters)
    (define b (binding 'm/a 'frob 'value 'm/private/impl '%frob "pkg"
                       (cons (exporter 'm/a 'frob '() #t) exporters) '(m/a)))
    (map (λ (w) (list (doc-warning-module w) (unreachable-docs-warning-id w)
                      (unreachable-docs-warning-use-source w)))
         (binding-warnings b (hash))))
  ;; m/b renames it itself, so nothing on its path exports it as frob
  (check-equal? (frob-warnings (exporter 'm/b 'frob '() #f)) '((m/b frob #f)))
  ;; m/c gets it from m/private/api, which renames it once; that's the module for #:use-sources
  (check-equal? (frob-warnings (exporter 'm/c 'frob '((m/private/api . frob)) #f))
                '((m/c frob m/private/api)))
  ;; m/d exports it under another name, and so does m/a, as an alias: each name is checked
  (check-equal? (frob-warnings (exporter 'm/d 'colour '() #f) (exporter 'm/a 'twiddle '() #f))
                '((m/d colour #f) (m/a twiddle #f)))

  ;; A module that exports a binding under more than one name reports it under the name that
  ;; connects to the docs, else the name it's defined under
  (check-equal? (id-in-module (list (exporter 'm/a 'build '() #f) (exporter 'm/a 'make '() #t))
                              'm/a 'make)
                'make)
  (check-equal? (id-in-module (list (exporter 'm/a 'build '() #f) (exporter 'm/a 'make '() #f))
                              'm/a 'make)
                'make)

  ;; Racket's main collections are skipped
  (check-equal? (check-coverage '(racket/list) #:packages '("base"))
                (coverage-report '() '() '() '()))

  (define b1 (struct-copy binding documented-foo))
  (define b2 (struct-copy binding documented-foo [doc-modules #f]))
  (check-equal? (coverage-ratio (list (module-coverage 'a (list b1) '())
                                      (module-coverage 'b '() (list b2))))
                1/2)
  (check-false (coverage-ratio '())))
