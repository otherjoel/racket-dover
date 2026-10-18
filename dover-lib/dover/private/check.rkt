#lang racket/base

(require pkg/lib
         racket/cmdline
         racket/list
         racket/match
         racket/string
         setup/getinfo
         "coverage.rkt"
         "report.rkt")

;; Implements `raco dover check`.

(define who (string->symbol "raco dover check"))

;; Configuration read from a package's top-level info.rkt
(struct config (modules ignore include-private min-coverage) #:transparent)

(define (ignore-spec? v)
  (or (module-path? v)
      (and (list? v) (pair? v) (module-path? (car v)) (andmap symbol? (cdr v)))))

(define (read-config pkg)
  (define dir (or (pkg-directory pkg)
                  (raise-user-error who "package is not installed: ~a" pkg)))
  (define info (get-info/full dir))
  (define (field key ok? what default)
    (define v (if info (info key (λ () default)) default))
    (unless (or (equal? v default) (ok? v))
      (raise-user-error who "~a in the info.rkt for ~a must be ~a\n  given: ~e" key pkg what v))
    v)
  (config (field 'dover-modules (λ (v) (and (list? v) (andmap module-path? v)))
                 "a list of module paths" #f)
          (field 'dover-ignore (λ (v) (and (list? v) (andmap ignore-spec? v)))
                 "a list of module paths or (module-path id ...) lists" '())
          (field 'dover-include-private (λ (v) (and (list? v) (andmap module-path? v)))
                 "a list of module paths" '())
          (field 'dover-min-coverage (λ (v) (and (real? v) (<= 0 v 100)))
                 "a number from 0 to 100" #f)))

(define (config-modules* cfg pkg include-private?)
  (or (config-modules cfg)
      (append (package-modules pkg #:include-private? include-private?)
              (config-include-private cfg))))

;; "mod" -> 'mod,  "mod:id" -> '(mod id). Module paths never contain a colon, but ids can.
(define (parse-ignore str)
  (match (regexp-match #rx"^([^:]+)(?::(.+))?$" str)
    [(list _ mod #f) (string->symbol mod)]
    [(list _ mod id) (list (string->symbol mod) (string->symbol id))]
    [_ (raise-user-error who "bad --ignore value: ~a" str)]))

(define (parse-min str)
  (define n (string->number str 10))
  (unless (and (real? n) (<= 0 n 100))
    (raise-user-error who "--min must be a number from 0 to 100, given: ~a" str))
  n)

(define (parse-format str)
  (define fmt (string->symbol str))
  (unless (memq fmt '(text json stubs))
    (raise-user-error who "--format must be text, json or stubs, given: ~a" str))
  fmt)

;; Returns the process exit status.
(define (run-check pkgs
                   #:include-private? include-private?
                   #:ignore extra-ignore
                   #:min-coverage cli-min
                   #:strict? strict?
                   #:format fmt)
  (define configs (map read-config pkgs))
  (define mods
    (sort (remove-duplicates
           (append* (for/list ([pkg (in-list pkgs)] [cfg (in-list configs)])
                      (map normalize-module-path (config-modules* cfg pkg include-private?)))))
          module<?))
  (define ignore (append (append-map config-ignore configs) extra-ignore))
  (define min-coverage (or cli-min (ormap config-min-coverage configs)))
  (define report (check-coverage mods #:packages pkgs #:ignore ignore))
  (define ratio (coverage-ratio (coverage-report-scored report)))

  (define notices
    (append
     (for/list ([e (in-list (coverage-report-errors report))])
       (format "could not load ~s: ~a" (car e) (cdr e)))
     (if (eqv? ratio 0)
         (list (format "no bindings have documentation; if ~a has docs, run `raco setup ~a` to build them"
                       (string-join pkgs ", ") (string-join pkgs " ")))
         '())))

  (case fmt
    [(text) (write-text-report report pkgs)]
    [(json) (write-json-report report pkgs notices)]
    [(stubs) (write-scribble-stubs report)])
  (flush-output)
  (unless (eq? fmt 'json)
    (for ([n (in-list notices)])
      (eprintf "warning: ~a\n" n)))

  (define below-min? (and min-coverage ratio (< (* ratio 100) min-coverage)))
  (define warning-count (length (coverage-report-warnings report)))
  (define fail-on-warnings? (and strict? (positive? warning-count)))
  (unless (eq? fmt 'json)
    (when below-min?
      (eprintf "Coverage ~a% is below the minimum of ~a%\n"
               (real->decimal-string (* ratio 100) 1) min-coverage))
    (when fail-on-warnings?
      (eprintf "~a documentation warning~a (--strict)\n"
               warning-count (if (= warning-count 1) "" "s"))))
  (if (or below-min? fail-on-warnings?) 1 0))

(module+ main
  (define include-private? #f)
  (define ignore '())
  (define min-coverage #f)
  (define strict? #f)
  (define fmt 'text)
  (define pkgs
    (command-line
     #:program "raco dover check"
     #:once-each
     [("--include-private") "Also check modules in private/ directories"
                            (set! include-private? #t)]
     [("--min") pct "Exit with status 1 if coverage is below <pct> percent"
                (set! min-coverage (parse-min pct))]
     [("--strict") "Exit with status 1 if there are any documentation warnings"
                   (set! strict? #t)]
     [("-f" "--format") format "Output format: text (default), json or stubs"
                        (set! fmt (parse-format format))]
     #:multi
     [("--ignore") spec "Ignore bindings from <module>, or one binding with <module>:<id>"
                   (set! ignore (cons (parse-ignore spec) ignore))]
     #:args (pkg . more-pkgs)
     (cons pkg more-pkgs)))
  (exit (run-check pkgs
                   #:include-private? include-private?
                   #:ignore (reverse ignore)
                   #:min-coverage min-coverage
                   #:strict? strict?
                   #:format fmt)))

(module+ test
  (require rackunit)
  (check-equal? (parse-ignore "a/b") 'a/b)
  (check-equal? (parse-ignore "a/b:foo") '(a/b foo))
  (check-equal? (parse-ignore "a/b:struct:foo") '(a/b struct:foo))
  (check-true (ignore-spec? 'a/b))
  (check-true (ignore-spec? '(a/b x y)))
  (check-false (ignore-spec? '(a/b "x"))))
