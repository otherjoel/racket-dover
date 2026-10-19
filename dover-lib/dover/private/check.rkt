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
(struct config (modules ignore never-ignore consider-private min-coverage) #:transparent)

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
          (field 'dover-never-ignore (λ (v) (and (list? v) (andmap module-path? v)))
                 "a list of module paths" '())
          (field 'dover-consider-private (λ (v) (and (list? v) (andmap module-path? v)))
                 "a list of module paths" '())
          (field 'dover-min-coverage (λ (v) (and (real? v) (<= 0 v 100)))
                 "a number from 0 to 100" #f)))

;; Modules in dover-consider-private are treated like modules in private/ directories: skipped
;; unless include-private? is true. Modules in dover-never-ignore are always checked.
(define (config-modules* cfg pkg include-private?)
  (cond
    [(config-modules cfg)
     => (λ (mods) (remove-considered-private cfg (map normalize-module-path mods) include-private?))]
    [else
     (append (remove-considered-private
              cfg
              (package-modules pkg #:include-private? include-private?)
              include-private?)
             (map normalize-module-path (config-never-ignore cfg)))]))

(define (remove-considered-private cfg mods include-private?)
  (define private (map normalize-module-path (config-consider-private cfg)))
  (if include-private?
      mods
      (filter (λ (m) (not (member m private))) mods)))

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

;; True for a module in a private/ directory
(define (in-private-dir? mod)
  (and (symbol? mod) (member "private" (string-split (symbol->string mod) "/")) #t))

;; How to stop checking mod, given the reason it was checked; see current-internal-module-fix.
(define (internal-fix-for mod
                          #:never-ignore never-ignore
                          #:consider-private consider-private
                          #:include-private? include-private?)
  (define private? (or (in-private-dir? mod) (and (member mod consider-private) #t)))
  (cond
    [(member mod never-ignore)
     (if private?
         "remove it from dover-never-ignore"
         "remove it from dover-never-ignore and list it in dover-consider-private")]
    [(and private? include-private?) #f] ; the user asked to check private modules
    ;; Also covers a module in a private/ directory that is listed in dover-modules
    [else "list it in dover-consider-private"]))

;; Returns the process exit status.
(define (run-check pkgs
                   #:include-private? include-private?
                   #:ignore extra-ignore
                   #:min-coverage cli-min
                   #:strict? strict?
                   #:format fmt
                   #:show-reexported? [show-reexported? #f])
  (define configs (map read-config pkgs))
  (define mods
    (sort (remove-duplicates
           (append* (for/list ([pkg (in-list pkgs)] [cfg (in-list configs)])
                      (config-modules* cfg pkg include-private?))))
          module<?))
  (define ignore (append (append-map config-ignore configs) extra-ignore))
  (define min-coverage (or cli-min (ormap config-min-coverage configs)))
  (define report (check-coverage mods #:packages pkgs #:ignore ignore))
  (define never-ignore (append-map (λ (c) (map normalize-module-path (config-never-ignore c)))
                                   configs))
  (define consider-private
    (append-map (λ (c) (map normalize-module-path (config-consider-private c))) configs))
  (define (internal-module-fix mod)
    (internal-fix-for mod
                      #:never-ignore never-ignore
                      #:consider-private consider-private
                      #:include-private? include-private?))
  (define ratio (coverage-ratio (coverage-report-scored report)))

  (define notices
    (append
     (for/list ([e (in-list (coverage-report-errors report))])
       (format "could not load ~s: ~a" (car e) (cdr e)))
     (if (eqv? ratio 0)
         (list (format "no bindings have documentation; if ~a has docs, run `raco setup ~a` to build them"
                       (string-join pkgs ", ") (string-join pkgs " ")))
         '())))

  (parameterize ([current-internal-module-fix internal-module-fix])
    (case fmt
      [(text) (write-text-report report pkgs #:show-reexported? show-reexported?)]
      [(json) (write-json-report report pkgs notices)]
      [(stubs) (write-scribble-stubs report)]))
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
  (define show-reexported? #f)
  (define pkgs
    (command-line
     #:program "raco dover check"
     #:once-each
     [("--include-private") "Also check modules in private/ directories and dover-consider-private"
                            (set! include-private? #t)]
     [("--min") pct "Exit with status 1 if coverage is below <pct> percent"
                (set! min-coverage (parse-min pct))]
     [("--strict") "Exit with status 1 if there are any documentation warnings"
                   (set! strict? #t)]
     [("-f" "--format") format "Output format: text (default), json or stubs"
                        (set! fmt (parse-format format))]
     [("--show-reexported") "Also list bindings re-exported from other packages (not scored)"
                            (set! show-reexported? #t)]
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
                   #:format fmt
                   #:show-reexported? show-reexported?)))

(module+ test
  (require rackunit)
  (define (fix mod #:include-private? [ip? #f])
    (internal-fix-for mod
                      #:never-ignore '(p/a p/private/x)
                      #:consider-private '(p/a p/b)
                      #:include-private? ip?))
  (check-equal? (fix 'p/a) "remove it from dover-never-ignore")
  (check-equal? (fix 'p/private/x) "remove it from dover-never-ignore")
  (check-false (fix 'p/b #:include-private? #t))
  (check-false (fix 'p/private/y #:include-private? #t))
  (check-equal? (fix 'p/c) "list it in dover-consider-private")
  (check-equal? (fix 'p/private/y) "list it in dover-consider-private")
  (check-equal? (internal-fix-for 'p/c
                                  #:never-ignore '(p/c)
                                  #:consider-private '()
                                  #:include-private? #f)
                "remove it from dover-never-ignore and list it in dover-consider-private")

  (check-equal? (parse-ignore "a/b") 'a/b)
  (check-equal? (parse-ignore "a/b:foo") '(a/b foo))
  (check-equal? (parse-ignore "a/b:struct:foo") '(a/b struct:foo))
  (check-true (ignore-spec? 'a/b))
  (check-true (ignore-spec? '(a/b x y)))
  (check-false (ignore-spec? '(a/b "x"))))
