#lang racket/base

;; Runs Dover on fixture packages. Dover reads installed docs, so each fixture in fixtures/ is
;; copied to a temporary directory, installed as a linked package (which builds its docs), checked
;; with `raco dover check -f json`, and removed again.

(require json
         pkg/lib
         racket/file
         racket/port
         racket/runtime-path
         racket/string
         setup/dirs)

(provide call-with-fixture
         call-with-fixtures
         dover-check
         dover-exit-status
         replace-fixture-docs!)

(define-runtime-path fixtures-dir "fixtures/")

(define raco
  (build-path (find-console-bin-dir) (if (eq? (system-type) 'windows) "raco.exe" "raco")))

;; Runs raco, returning its exit status and its stdout and stderr together
(define (run-raco . args)
  (define-values (sp out in _err)
    (apply subprocess #f #f 'stdout raco args))
  (close-output-port in)
  (define output (port->string out))
  (close-input-port out)
  (subprocess-wait sp)
  (values (subprocess-status sp) output))

(define (raco! . args)
  (define-values (status output) (apply run-raco args))
  (unless (zero? status)
    (error 'raco "command failed: raco ~a\n~a" (string-join args) output)))

;; Installs a copy of fixtures/<name> and calls proc with the copy's directory. The fixture's
;; directory name is its package name.
(define (call-with-fixture name proc)
  (call-with-fixtures (list name) proc))

;; Like call-with-fixture, but installs several fixtures together and calls proc with each copy's
;; directory
(define (call-with-fixtures names proc)
  (for ([name (in-list names)])
    (when (pkg-directory name)
      (error 'call-with-fixtures "a package named ~a is already installed" name)))
  (define tmp (make-temporary-directory "dover-test-~a"))
  (define dirs (for/list ([name (in-list names)]) (build-path tmp name)))
  (for ([name (in-list names)] [dir (in-list dirs)])
    (copy-directory/files (build-path fixtures-dir name) dir))
  (dynamic-wind
   void
   (λ ()
     (apply raco! "pkg" "install" "--link" (map path->string dirs))
     (apply proc dirs))
   (λ ()
     (define installed (filter pkg-directory names))
     (unless (null? installed)
       (apply raco! "pkg" "remove" installed))
     (delete-directory/files tmp))))

;; Returns the JSON report of `raco dover check` for pkg
(define (dover-check pkg . flags)
  (define-values (_status output)
    (apply run-raco "dover" "check" "-f" "json" (append flags (list pkg))))
  (string->jsexpr output))

;; Returns the exit status of `raco dover check` for pkg
(define (dover-exit-status pkg . flags)
  (define-values (status _output)
    (apply run-raco "dover" "check" "-f" "json" (append flags (list pkg))))
  status)

;; Replaces the installed fixture's docs (at rel-path in dir) with fixtures/<file>, and rebuilds
;; them
(define (replace-fixture-docs! name dir rel-path file)
  (copy-file (build-path fixtures-dir file) (build-path dir rel-path) #t)
  (raco! "setup" "--pkgs" name))
