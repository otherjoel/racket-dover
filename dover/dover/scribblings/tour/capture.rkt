#lang racket/base

;; Captures the `raco dover` output shown in the Quick Tour section of dover.scrbl. Run it
;; whenever the sample package or Dover's report changes, then rebuild the docs:
;;
;;   racket dover/dover/scribblings/tour/capture.rkt
;;
;; It copies the sample package in tally/ to a temporary directory, installs it as a linked
;; package (which builds its docs), runs each command, and removes the package again. The output
;; of each command, ANSI colors included, goes to output/<name>.txt, after a first line that
;; holds the command itself.

(require pkg/lib
         racket/file
         racket/port
         racket/runtime-path
         racket/string
         setup/dirs)

(define-runtime-path sample-dir "tally/")
(define-runtime-path fixed-docs "tally-fixed.scrbl")
(define-runtime-path output-dir "output/")

(define pkg "tally")
(define raco (build-path (find-console-bin-dir) "raco"))

;; Runs raco, letting its output go to the console
(define (run-raco . args)
  (printf "\n$ raco ~a\n" (string-join args))
  (unless (apply system*/ok? args)
    (error 'capture "command failed: raco ~a" (string-join args))))

(define (system*/ok? . args)
  (define-values (sp _out _in _err)
    (apply subprocess (current-output-port) #f (current-error-port) raco args))
  (subprocess-wait sp)
  (zero? (subprocess-status sp)))

;; Runs raco with color forced on, and saves its stdout and stderr together to output/<name>.txt
(define (capture name . args)
  (define cmd (string-append "raco " (string-join args)))
  (printf "\n$ ~a  > output/~a.txt\n" cmd name)
  (define env (environment-variables-copy (current-environment-variables)))
  (environment-variables-set! env #"FORCE_COLOR" #"1")
  (environment-variables-set! env #"NO_COLOR" #f)
  (define-values (sp out in _err)
    (parameterize ([current-environment-variables env])
      (apply subprocess #f #f 'stdout raco args)))
  (close-output-port in)
  (define text (port->string out))
  (close-input-port out)
  (subprocess-wait sp)
  (call-with-output-file (build-path output-dir (string-append name ".txt")) #:exists 'truncate
    (λ (o) (fprintf o "~a\n~a" cmd text))))

(module+ main
  (when (pkg-directory pkg)
    (error 'capture "a package named ~a is already installed" pkg))
  (make-directory* output-dir)
  (define tmp (make-temporary-directory "dover-tour-~a"))
  (define pkg-dir (build-path tmp pkg))
  (copy-directory/files sample-dir pkg-dir)
  (dynamic-wind
   void
   (λ ()
     (run-raco "pkg" "install" "--link" (path->string pkg-dir))
     (capture "check" "dover" "check" pkg)
     (capture "stubs" "dover" "check" "-f" "stubs" pkg)
     (copy-file fixed-docs (build-path pkg-dir "scribblings" "tally.scrbl") #t)
     (run-raco "setup" "--pkgs" pkg)
     (capture "check-fixed" "dover" "check" pkg))
   (λ ()
     (run-raco "pkg" "remove" pkg)
     (delete-directory/files tmp))))
