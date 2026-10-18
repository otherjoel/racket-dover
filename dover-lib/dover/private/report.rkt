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
                                           (all-of module-coverage-unreachable)
                                           (all-of module-coverage-missing))))
          string<?))
  (for/list ([pkg (in-list pkgs)])
    (define (in-pkg sel)
      (filter (λ (b) (equal? (binding-source-pkg b) pkg)) (all-of sel)))
    (module-coverage pkg
                     (in-pkg module-coverage-documented)
                     (in-pkg module-coverage-unreachable)
                     (in-pkg module-coverage-missing))))

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

(define (format-binding-source b #:show-exporter? show-exporter?)
  (define renamed? (not (eq? (binding-source-id b) (binding-id b))))
  (define parts
    (append
     (if (or renamed? (not (equal? (binding-source-module b) (binding-module b))))
         (list (format "from ~a~a"
                       (module->string (binding-source-module b))
                       (if renamed? (format " as ~a" (binding-source-id b)) "")))
         '())
     (if show-exporter?
         (list (format "exported by ~a" (module->string (binding-module b))))
         '())))
  (if (null? parts) "" (format "  (~a)" (string-join parts ", "))))

;; Lists the bindings without documentation. Returns #t if it printed anything.
(define (write-missing mcs #:show-exporter? show-exporter?)
  (for/fold ([printed? #f]) ([mc (in-list mcs)])
    (match-define (module-coverage label _ unreachable missing) mc)
    (define miss-count (+ (length missing) (length unreachable)))
    (cond
      [(zero? miss-count) printed?]
      [else
       (define total (module-coverage-total mc))
       (term-bytes (if (<= (/ miss-count total) 3/10) color:yellow color:red))
       (printf "~a  [missing ~a of ~a]:\n" (module->string label) miss-count total)
       (term-bytes color:reset)
       (for ([b (in-list missing)])
         (printf "  ~a~a\n" (binding-id b)
                 (format-binding-source b #:show-exporter? show-exporter?)))
       (for ([b (in-list unreachable)])
         (printf "  ~a  (documented in ~a, but not reachable from ~a)\n"
                 (binding-id b)
                 (module->string (binding-documented-via b))
                 (module->string (binding-module b))))
       #t])))

(define (write-section title mcs #:show-exporter? [show-exporter? #f])
  (write-header title)
  (when (write-missing mcs #:show-exporter? show-exporter?)
    (newline))
  (for ([mc (in-list mcs)])
    (write-bar-line (module->string (module-coverage-module mc))
                    (length (module-coverage-documented mc))
                    (module-coverage-total mc)))
  (write-separator)
  (define-values (documented total) (coverage-totals mcs))
  (write-bar-line "Total" documented total))

;; The scored section is grouped by the module that exports each binding; the unscored section by
;; the package that defines it.
(define (write-text-report report pkgs)
  (define scored (coverage-report-scored report))
  (define unscored (by-source-package (coverage-report-unscored report)))
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
                   #:show-exporter? #t)))

;;================================================
;; JSON

(define (binding->jsexpr b)
  (hasheq 'id (symbol->string (binding-id b))
          'kind (symbol->string (binding-kind b))
          'source_module (module->string (binding-source-module b))
          'source_id (symbol->string (binding-source-id b))
          'source_pkg (binding-source-pkg b)))

(define (module-coverage->jsexpr mc key)
  (match-define (module-coverage label documented unreachable missing) mc)
  (hasheq key (module->string label)
          'total (module-coverage-total mc)
          'documented (length documented)
          'unreachable (map binding->jsexpr unreachable)
          'missing (map binding->jsexpr missing)))

(define (coverage->jsexpr mcs group-key key)
  (define-values (documented total) (coverage-totals mcs))
  (define ratio (coverage-ratio mcs))
  (hasheq 'documented documented
          'total total
          'coverage (if ratio (exact->inexact ratio) (json-null))
          group-key (for/list ([mc (in-list mcs)]) (module-coverage->jsexpr mc key))))

(define (write-json-report report pkgs warnings)
  (match-define (coverage-report scored unscored errors) report)
  (write-json
   (hasheq 'packages pkgs
           'scored (coverage->jsexpr scored 'modules 'module)
           'unscored (coverage->jsexpr (by-source-package unscored) 'packages 'package)
           'errors (for/list ([e (in-list errors)])
                     (hasheq 'module (module->string (car e)) 'message (cdr e)))
           'warnings warnings))
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
