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
         dover-check
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
  (when (pkg-directory name)
    (error 'call-with-fixture "a package named ~a is already installed" name))
  (define tmp (make-temporary-directory "dover-test-~a"))
  (define dir (build-path tmp name))
  (copy-directory/files (build-path fixtures-dir name) dir)
  (dynamic-wind
   void
   (λ ()
     (raco! "pkg" "install" "--link" (path->string dir))
     (proc dir))
   (λ ()
     (when (pkg-directory name)
       (raco! "pkg" "remove" name))
     (delete-directory/files tmp))))

;; Returns the JSON report of `raco dover check` for pkg
(define (dover-check pkg . flags)
  (define-values (_status output)
    (apply run-raco "dover" "check" "-f" "json" (append flags (list pkg))))
  (string->jsexpr output))

;; Replaces the installed fixture's docs (at rel-path in dir) with fixtures/<file>, and rebuilds
;; them
(define (replace-fixture-docs! name dir rel-path file)
  (copy-file (build-path fixtures-dir file) (build-path dir rel-path) #t)
  (raco! "setup" "--pkgs" name))
