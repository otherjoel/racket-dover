#lang racket/base

(require json
         racket/format
         racket/list
         racket/string
         racket/match
         racket/promise
         "coverage.rkt")

(provide current-internal-module-fix
         write-text-report
         write-json-report
         write-scribble-stubs)

(define (module->string mod)
  (cond
    [(symbol? mod) (symbol->string mod)]
    [(string? mod) mod]
    [else (~s mod)]))

;; Regroups results by the package that defines each binding. The module field of each result
;; holds the package name.
(define (by-source-package mcs)
  (define (all-of sel)
    (for*/list ([mc (in-list mcs)] [b (in-list (sel mc))]) b))
  (define pkgs
    (sort (remove-duplicates
           (map binding-source-pkg (append (all-of module-coverage-documented)
                                           (all-of module-coverage-missing))))
          string<?))
  (for/list ([pkg (in-list pkgs)])
    (define (in-pkg sel)
      (filter (λ (b) (equal? (binding-source-pkg b) pkg)) (all-of sel)))
    (module-coverage pkg
                     (in-pkg module-coverage-documented)
                     (in-pkg module-coverage-missing))))

;; A module that exports a binding under more than one name has an exporter for each, so remove
;; duplicates
(define (exporter-modules b)
  (remove-duplicates (map exporter-module (binding-exporters b))))

(define (modules->string mods)
  (string-join (map module->string mods) ", "))

;;================================================
;; Warnings

(define (warning-message w)
  (match-define (doc-warning b mod) w)
  (match w
    [(unreachable-docs-warning _ _ id doc-id _)
     (format "~a: ~a is documented~a, but as exported by this module it doesn't connect to its docs"
             (module->string mod) id (if (eq? id doc-id) "" (format " (as ~a)" doc-id)))]
    [(? export-claim-warning?)
     (format "~a: the docs say this module exports ~a, but it doesn't"
             (module->string mod) (binding-id b))]))

;; Given a checked module, returns how to stop checking it (for example, "list it in
;; dover-consider-private"), or #f if there is nothing to suggest. This depends on the reason the
;; module was checked, which only the caller knows.
(define current-internal-module-fix
  (make-parameter (λ (_mod) "list it in dover-consider-private")))

;; The fix for an unreachable-docs warning, not counting the internal-module alternative. one? says
;; whether it is for one binding or several; warnings with the same fix are listed together.
;;  - If a module on the binding's re-export path exports it under the name the docs use, adding
;;    that module to #:use-sources connects it.
;;  - If the module exports it under that name but gives it the name itself, no #:use-sources can:
;;    Scribble matches #:use-sources modules by name.
;;  - If the module exports it under another name, that name needs its own docs.
(define (unreachable-fix w one?)
  (match-define (unreachable-docs-warning b _ id doc-id use-source) w)
  (define it (if one? "it" "them"))
  (define doc-mods (binding-doc-modules b))
  (define doc-mod (and (pair? doc-mods) (module->string (car doc-mods))))
  (cond
    [use-source
     (format "add ~a to the #:use-sources of the defmodule or declare-exporting ~a"
             (module->string use-source)
             (if doc-mod (format "for ~a" doc-mod) (format "that documents ~a" it)))]
    [(eq? id doc-id)
     (format (string-append "this module renames ~a itself, so no #:use-sources can connect ~a; "
                            "rename ~a in one module that every public module re-exports ~a from, "
                            "and add that module to the #:use-sources~a")
             it it it it
             (if doc-mod (format ", or have this module re-export ~a from ~a" it doc-mod) ""))]
    [else
     (format (string-append "the docs cover ~a only under another name; document ~a under ~a "
                            "name~a too (for example, with deftogether)")
             it it (if one? "this" "these") (if one? "" "s"))]))

;; Returns #f if there is nothing to suggest
(define (internal-module-fix mod)
  (define fix ((current-internal-module-fix) mod))
  (and fix (format "if ~a is internal, ~a" (module->string mod) fix)))

;; ids : what to call the binding(s), such as "foo" or "them"
(define (export-claim-fix mod docs ids)
  (format "remove ~a from the declare-exporting that documents ~a, or provide ~a from ~a"
          (module->string mod) docs ids (module->string mod)))

(define (warning-fix w)
  (match-define (doc-warning b mod) w)
  (match w
    [(? unreachable-docs-warning?)
     (define internal-fix (internal-module-fix mod))
     (string-append (unreachable-fix w #t)
                    (if internal-fix (string-append "; or, " internal-fix) ""))]
    [(? export-claim-warning?)
     (export-claim-fix mod (binding-id b) (binding-id b))]))

;;================================================
;; Terminal output

;; FORCE_COLOR turns on color even when the output is not a terminal (see force-color.org)
(define color? (delay (and (or (terminal-port? (current-output-port))
                               (non-empty-env? "FORCE_COLOR"))
                           (not (getenv "NO_COLOR")))))

(define (non-empty-env? name)
  (define v (getenv name))
  (and v (not (string=? v "")) #t))

(define (term-bytes . b)
  (when (force color?) (for-each write-bytes b)))

;; From https://github.com/lexi-lambda/racket-commonmark/blob/master/commonmark-test/tests/commonmark/spec.rkt
(define color:bold #"\e[1m")
(define color:italic #"\e[3m")
(define color:red #"\e[31m")
(define color:green #"\e[32m")
(define color:yellow #"\e[33m")
(define color:gray #"\e[90m")
(define color:reset #"\e(B\e[m")

(define bar-width 50)
(define section-title-width (make-parameter 10))
(define totals-width (make-parameter 10))

(define (write-chars c len)
  (write-string (make-string len c)))

(define (write-separator)
  (write-chars #\─ (+ (section-title-width) (* (totals-width) 2) bar-width 8))
  (newline))

(define (write-header str)
  (term-bytes color:bold)
  (write-string str)
  (term-bytes color:reset)
  (newline)
  (write-separator))

(define (score-color score)
  (cond
    [(= score 1) color:green]
    [(>= score 7/10) color:yellow]
    [else color:red]))

(define (write-bar-line label successes total)
  (write-string (~a label #:width (section-title-width) #:align 'right))
  (write-string " ")
  (define score (/ successes total))
  (term-bytes (score-color score))
  (define filled-chars (round (* score bar-width)))
  (write-chars #\█ filled-chars)
  (write-chars #\░ (- bar-width filled-chars))
  (write-string " ")
  (write-string (~r (* score 100) #:precision 0 #:min-width 3))
  (write-string "%")
  (term-bytes color:gray)
  (write-string (~a " " (~r successes #:min-width (totals-width)) "/" total))
  (term-bytes color:reset)
  (newline))

(define (format-binding-details b #:show-exporters? show-exporters?)
  (define renamed? (not (eq? (binding-source-id b) (binding-id b))))
  (define parts
    (append
     (if (or renamed? (not (equal? (binding-source-module b) (binding-module b))))
         (list (format "defined in ~a~a"
                       (module->string (binding-source-module b))
                       (if renamed? (format " as ~a" (binding-source-id b)) "")))
         '())
     (if (or show-exporters? (not (equal? (exporter-modules b) (list (binding-module b)))))
         (list (format "exported by ~a" (modules->string (exporter-modules b))))
         '())))
  (if (null? parts) "" (format "  (~a)" (string-join parts "; "))))

;; Lists the bindings without documentation. Returns #t if it printed anything.
(define (write-missing mcs #:show-exporters? show-exporters?)
  (for/fold ([printed? #f]) ([mc (in-list mcs)])
    (match-define (module-coverage label _ missing) mc)
    (cond
      [(null? missing) printed?]
      [else
       (define total (module-coverage-total mc))
       (term-bytes (if (<= (/ (length missing) total) 3/10) color:yellow color:red))
       (printf "~a  [missing ~a of ~a]:\n" (module->string label) (length missing) total)
       (term-bytes color:reset)
       (for ([b (in-list missing)])
         (printf "  ~a~a\n" (binding-id b)
                 (format-binding-details b #:show-exporters? show-exporters?)))
       #t])))

(define (write-section title mcs #:show-exporters? [show-exporters? #f])
  (write-header title)
  (when (write-missing mcs #:show-exporters? show-exporters?)
    (newline))
  (for ([mc (in-list mcs)])
    (write-bar-line (module->string (module-coverage-module mc))
                    (length (module-coverage-documented mc))
                    (module-coverage-total mc)))
  (write-separator)
  (define-values (documented total) (coverage-totals mcs))
  (write-bar-line "Total" documented total))

;; Groups xs by (key x), in the order in which each key first appears
(define (group-by-key xs key)
  (for/list ([k (in-list (remove-duplicates (map key xs)))])
    (cons k (filter (λ (x) (equal? (key x) k)) xs))))

;; Lists each module once, followed by its warnings of each kind: a description, the bindings,
;; and the fix.
(define (write-warnings warnings)
  (write-header (format "Documentation warnings (~a)" (length warnings)))
  (for ([g (in-list (group-by-key warnings doc-warning-module))])
    (match-define (cons mod ws) g)
    (term-bytes color:yellow)
    (printf "~a:\n" (module->string mod))
    (term-bytes color:reset)
    (write-unreachable-warnings mod (filter unreachable-docs-warning? ws))
    (write-export-claim-warnings mod (filter export-claim-warning? ws))))

(define (write-unreachable-warnings mod ws)
  (unless (null? ws)
    (define one? (null? (cdr ws)))
    (printf "  ~a documented, but as exported by this module ~a connect to ~a docs:\n"
            (if one? "This binding is" "These bindings are")
            (if one? "it doesn't" "they don't")
            (if one? "its" "their"))
    ;; Bindings that need different fixes are listed separately, each with its fix
    (for ([g (in-list (group-by-key ws (λ (w) (unreachable-fix w #t))))])
      (define g-ws (cdr g))
      (for ([w (in-list g-ws)])
        (match-define (unreachable-docs-warning _ _ id doc-id _) w)
        (printf "    ~a~a\n" id (if (eq? id doc-id) "" (format "  (documented as ~a)" doc-id))))
      (printf "  fix: ~a\n" (unreachable-fix (car g-ws) (null? (cdr g-ws)))))
    (define internal-fix (internal-module-fix mod))
    (when internal-fix
      (printf "   or: ~a\n" internal-fix))))

(define (write-export-claim-warnings mod ws)
  (unless (null? ws)
    (define one? (null? (cdr ws)))
    (printf "  The docs say this module exports ~a, but it doesn't:\n"
            (if one? "this binding" "these bindings"))
    (for ([w (in-list ws)])
      (printf "    ~a\n" (binding-id (doc-warning-binding w))))
    (printf "  fix: ~a\n" (if one?
                              (export-claim-fix mod "it" "it")
                              (export-claim-fix mod "them" "them")))))

;; The scored section is grouped by the module each binding is reported under; the unscored
;; section by the package that defines it.
(define (write-text-report report pkgs)
  (define scored (coverage-report-scored report))
  (define unscored (by-source-package (coverage-report-unscored report)))
  (define warnings (coverage-report-warnings report))
  (define all (append scored unscored))
  (section-title-width
   (apply max 5 (for/list ([mc (in-list all)])
                  (string-length (module->string (module-coverage-module mc))))))
  (totals-width
   (string-length (~a (for/sum ([mc (in-list all)]) (module-coverage-total mc)))))
  (cond
    [(null? scored)
     (printf "No bindings to check in ~a.\n" (string-join pkgs ", "))]
    [else
     (write-section (format "Documentation coverage: ~a" (string-join pkgs ", ")) scored)])
  (unless (null? unscored)
    (newline)
    (write-section "Re-exported from other packages (not scored)" unscored
                   #:show-exporters? #t))
  (unless (null? warnings)
    (newline)
    (write-warnings warnings)))

;;================================================
;; JSON

(define (binding->jsexpr b)
  (hasheq 'id (symbol->string (binding-id b))
          'kind (symbol->string (binding-kind b))
          'source_module (module->string (binding-source-module b))
          'source_id (symbol->string (binding-source-id b))
          'source_pkg (binding-source-pkg b)
          'exported_by (map module->string (exporter-modules b))
          'documented_in (let ([mods (binding-doc-modules b)])
                           (if mods (map module->string mods) (json-null)))))

(define (module-coverage->jsexpr mc key)
  (match-define (module-coverage label documented missing) mc)
  (hasheq key (module->string label)
          'total (module-coverage-total mc)
          'documented (length documented)
          'missing (map binding->jsexpr missing)))

(define (coverage->jsexpr mcs group-key key)
  (define-values (documented total) (coverage-totals mcs))
  (define ratio (coverage-ratio mcs))
  (hasheq 'documented documented
          'total total
          'coverage (if ratio (exact->inexact ratio) (json-null))
          group-key (for/list ([mc (in-list mcs)]) (module-coverage->jsexpr mc key))))

(define (warning->jsexpr w)
  (match-define (doc-warning b mod) w)
  (define base
    (hasheq 'type (if (unreachable-docs-warning? w) "unreachable_docs" "export_claim")
            'module (module->string mod)
            'binding (binding->jsexpr b)
            'message (warning-message w)
            'fix (warning-fix w)))
  (match w
    [(unreachable-docs-warning _ _ id doc-id use-source)
     (hash-set* base
                'id (symbol->string id)
                'documented_as (symbol->string doc-id)
                'use_source (if use-source (module->string use-source) (json-null)))]
    [_ base]))

;; notices : (listof string), problems with the check itself (such as docs not being built)
(define (write-json-report report pkgs notices)
  (match-define (coverage-report scored unscored warnings errors) report)
  (write-json
   (hasheq 'packages pkgs
           'scored (coverage->jsexpr scored 'modules 'module)
           'unscored (coverage->jsexpr (by-source-package unscored) 'packages 'package)
           'warnings (map warning->jsexpr warnings)
           'errors (for/list ([e (in-list errors)])
                     (hasheq 'module (module->string (car e)) 'message (cdr e)))
           'notices notices))
  (newline))

;;================================================
;; Scribble stubs

;; Comments are gray and italic, and the def forms bold, when the output is a terminal
(define (write-stub-comment str)
  (term-bytes color:gray color:italic)
  (write-string (~a "@; " str))
  (term-bytes color:reset)
  (newline))

;; Formatted as most of Racket's own docs are: a blank line after the opening brace, and the
;; closing brace at the end of the text
(define (write-stub-def b)
  (define id (binding-id b))
  (term-bytes color:bold)
  (case (binding-kind b)
    [(value) (write-string (~a "@defproc[(" id " [arg any/c]) any/c]{"))]
    [(syntax) (write-string (~a "@defform[(" id " arg)\n"
                                "         #:contracts ([arg any/c])]{"))])
  ;; A sentence to finish, as a placeholder
  (write-string (~a "\n\n" (if (eq? (binding-kind b) 'value) "Returns a value that" "Expands to code that")
                    " ...}"))
  (term-bytes color:reset)
  (write-string "\n\n"))

;; A stub names at most this many of its siblings
(define max-sibling-names 3)

;; "a, b, c", or "a, b, c and 2 others" when there are more than n ids
(define (names-up-to ids n)
  (define shown (string-join (map ~a (if (> (length ids) n) (take ids n) ids)) ", "))
  (define more (- (length ids) n))
  (cond
    [(<= more 0) shown]
    [else (format "~a and ~a other~a" shown more (if (= more 1) "" "s"))]))

;; Prints Scribble stubs for the scored bindings that have no documentation, grouped by the
;; module they are reported under. A module that has no docs yet gets a defmodule; for one that
;; does, a comment suggests adding the stubs under its defmodule or declare-exporting. Since a
;; module's docs can span several sections, each stub is also placed near some of its siblings
;; (the documented bindings defined in the same module).
;;
;; Stubs with the same siblings get the same advice, so they are listed together. When all of a
;; module's stubs have the same siblings, all the advice goes at the top; otherwise each group of
;; stubs gets its own advice, after a separator line.
(define (write-scribble-stubs report)
  (define scored (coverage-report-scored report))
  (define documented-modules
    (remove-duplicates
     (for*/list ([mc (in-list scored)]
                 [b (in-list (module-coverage-documented mc))]
                 [m (in-list (binding-doc-modules b))])
       m)))
  (define (these bs) (if (null? (cdr bs)) "this" "these"))
  (define (near-advice siblings)
    (~a "near the existing docs for " (names-up-to siblings max-sibling-names)))
  (for ([mc (in-list scored)] #:unless (null? (module-coverage-missing mc)))
    (match-define (module-coverage mod documented missing) mc)
    (define (siblings b)
      (for/list ([d (in-list documented)]
                 #:when (equal? (binding-source-module d) (binding-source-module b)))
        (binding-id d)))
    (define groups (group-by-key missing siblings))
    (define module-advice
      (cond
        [(module-has-defmodule? mod)
         (~a "under the existing defmodule for " (module->string mod))]
        [(member mod documented-modules)
         (~a "under an existing declare-exporting for " (module->string mod))]
        [else #f]))
    (write-stub-comment (make-string 48 #\═))
    (unless module-advice
      (term-bytes color:bold)
      (write-string (~a "@defmodule[" (module->string mod) "]"))
      (term-bytes color:reset)
      (newline))
    (cond
      [(null? (cdr groups))
       (define advice
         (filter values (list module-advice
                              (and (pair? (caar groups)) (near-advice (caar groups))))))
       ;; One comment line for each piece of advice
       (for ([a (in-list advice)] [i (in-naturals)])
         (write-stub-comment (~a (if (zero? i) (~a "Suggestion: add " (these missing) " ") "")
                                 a
                                 (if (< i (sub1 (length advice))) "," ""))))
       (newline)
       (for-each write-stub-def missing)]
      [else
       (when module-advice
         (write-stub-comment (~a "Suggestion: add these " module-advice)))
       (newline)
       (for ([g (in-list groups)])
         (match-define (cons sibs bs) g)
         (write-stub-comment (make-string 48 #\─))
         (unless (null? sibs)
           (write-stub-comment (~a "Suggestion: add " (these bs) " " (near-advice sibs))))
         (for-each write-stub-def bs))])))

(module+ test
  (require rackunit)
  (check-equal? (names-up-to '(a b) 3) "a, b")
  (check-equal? (names-up-to '(a b c) 3) "a, b, c")
  (check-equal? (names-up-to '(a b c d) 3) "a, b, c and 1 other")
  (check-equal? (names-up-to '(a b c d e) 3) "a, b, c and 2 others"))
