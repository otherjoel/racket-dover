#lang racket/base

(require racket/format
         racket/match
         setup/getinfo)

;; Implements `raco dover`. Each subcommand comes from a `dover-subcommands` field in some
;; collection's info.rkt, so other packages can add subcommands:
;;
;;   (define dover-subcommands '(("name" module-path "description")))
;;
;; The dispatcher runs the `main` submodule of module-path with the remaining arguments.

(define (subcommand? v)
  (match v
    [(list (? string?) (? module-path?) (? string?)) #t]
    [_ #f]))

(define (find-subcommands)
  (sort
   (for*/list ([dir (in-list (find-relevant-directories '(dover-subcommands)))]
               [info (in-value (get-info/full dir))]
               #:when info
               [entry (in-list (info 'dover-subcommands (λ () '())))]
               #:when (subcommand? entry))
     entry)
   string<? #:key car))

(define (show-help cmds [out (current-output-port)])
  (fprintf out "Usage: raco dover <subcommand> <arg> ...\n\nSubcommands:\n")
  (define width (apply max 0 (map (λ (c) (string-length (car c))) cmds)))
  (for ([c (in-list cmds)])
    (fprintf out "  ~a  ~a\n" (~a (car c) #:min-width width) (caddr c)))
  (fprintf out "\nFor help on a subcommand: raco dover <subcommand> --help\n"))

(module+ main
  (define cmds (find-subcommands))
  (match (vector->list (current-command-line-arguments))
    [(or '() (list (or "-h" "--help" "help")))
     (show-help cmds)]
    [(cons name args)
     (match (assoc name cmds)
       [(list _ mod _)
        (parameterize ([current-command-line-arguments (list->vector args)])
          (dynamic-require `(submod ,mod main) #f))]
       [#f
        (eprintf "raco dover: unknown subcommand: ~a\n\n" name)
        (show-help cmds (current-error-port))
        (exit 1)])]))
