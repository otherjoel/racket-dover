#lang racket/base

(require json
         racket/format
         racket/list
         racket/string
         racket/match
         racket/promise
         "coverage.rkt")

(provide write-text-report
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

(define (exporter-modules b)
  (map exporter-module (binding-exporters b)))

;; The name the binding has in mod, one of its exporters
(define (id-in b mod)
  (cond [(findf (λ (e) (equal? (exporter-module e) mod)) (binding-exporters b)) => exporter-id]
        [else (binding-id b)]))

(define (modules->string mods)
  (string-join (map module->string mods) ", "))

;;================================================
;; Warnings

(define (warning-message w)
  (match-define (doc-warning b mod) w)
  (match w
    [(? unreachable-docs-warning?)
     (format "~a: Scribble can't find the docs for ~a from this module"
             (module->string mod) (id-in b mod))]
    [(? export-claim-warning?)
     (format "~a: the docs say this module exports ~a, but it doesn't"
             (module->string mod) (binding-id b))]))

(define (warning-fix w)
  (match-define (doc-warning b mod) w)
  (define doc-mods (binding-doc-modules b))
  (match w
    [(? unreachable-docs-warning?)
     (format (string-append "add ~a to the #:use-sources of the defmodule or declare-exporting~a;"
                            " or, if ~a is internal, list it in dover-consider-private")
             (module->string (binding-source-module b))
             (if (null? doc-mods)
                 " that documents it"
                 (format " for ~a" (module->string (car doc-mods))))
             (module->string mod))]
    [(? export-claim-warning?)
     (format "remove ~a from the declare-exporting that documents ~a, or provide ~a from ~a"
             (module->string mod) (binding-id b) (binding-id b) (module->string mod))]))

;;================================================
;; Terminal output

(define color? (delay (and (terminal-port? (current-output-port))
                           (not (getenv "NO_COLOR")))))

(define (term-bytes . b)
  (when (force color?) (for-each write-bytes b)))

;; From https://github.com/lexi-lambda/racket-commonmark/blob/master/commonmark-test/tests/commonmark/spec.rkt
(define color:bold #"\e[1m")
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

(define (write-warnings warnings)
  (write-header (format "Documentation warnings (~a)" (length warnings)))
  (for ([w (in-list warnings)])
    (term-bytes color:yellow)
    (write-string (warning-message w))
    (term-bytes color:reset)
    (newline)
    (printf "  fix: ~a\n" (warning-fix w))))

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
  (hasheq 'type (if (unreachable-docs-warning? w) "unreachable_docs" "export_claim")
          'module (module->string mod)
          'binding (binding->jsexpr b)
          'message (warning-message w)
          'fix (warning-fix w)))

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

(define (stub-scribble-def b)
  (define id (binding-id b))
  (case (binding-kind b)
    [(value)
     (~a "@defproc[(" id " [arg any/c]) any/c]{\n\n"
         id " proc\n\n"
         "}\n\n")]
    [(syntax)
     (~a "@defform[(" id " arg)\n"
         "         #:contracts ([arg any/c])]{\n\n"
         id " form\n\n"
         "}\n\n")]))

;; Prints Scribble stubs for the scored bindings that have no documentation.
(define (write-scribble-stubs report)
  (for ([mc (in-list (coverage-report-scored report))])
    (define missing (module-coverage-missing mc))
    (unless (null? missing)
      (write-string (~a "@;================================================\n\n"
                        "@defmodule[" (module->string (module-coverage-module mc)) "]\n\n"))
      (for ([b (in-list missing)])
        (write-string (stub-scribble-def b))))))
