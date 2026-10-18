#lang racket/base

(require racket/file
         racket/list
         racket/runtime-path
         racket/string
         scribble/core
         scribble/html-properties
         scribble/manual)

;; Helpers for the Quick Tour: showing the sample package's files, and showing terminal output
;; captured by tour/capture.rkt.

(provide tour-file
         tour-output)

(define-runtime-path terminal-css "terminal.css")
(define-runtime-path tour-dir "tour/")

(define (styled class content)
  (element (style class (list (css-style-addition terminal-css))) content))

;; Shows a file from the sample package, or the fixed docs. Pass `as` to label it with a name
;; other than its path in tour/.
(define (tour-file path #:as [label path])
  ;; Trimmed so that the file's final newline doesn't show as an empty line
  (define code (string-trim (file->string (build-path tour-dir path)) #:left? #f))
  ;; As codeblock does
  (filebox label (code-inset (typeset-code #:indent 0 code))))

;;================================================
;; Terminal output

;; Shows the command and output saved in tour/output/<name>.txt
(define (tour-output name)
  (define lines
    (file->lines (build-path tour-dir "output" (string-append name ".txt"))))
  (nested
   #:style (style "terminal" (list (css-style-addition terminal-css) (alt-tag "div")))
   (apply verbatim
          (add-between
           (cons (styled "term-prompt" (text->content (car lines)))
                 (ansi-lines->content (cdr lines)))
           "\n"))))

;; Like verbatim, renders runs of spaces as hspace so that they are kept exactly
(define (text->content str)
  (define m (regexp-match-positions #rx"(?:^| ) +" str))
  (cond
    [(not m) (list (tt str))]
    [else
     (define start (caar m))
     (define end (cdar m))
     (list* (tt (substring str 0 start))
            (hspace (- end start))
            (text->content (substring str end)))]))

;; The SGR codes that Dover's text report uses, and the CSS class for each
(define sgr-classes
  (hash "1" "term-bold"
        "31" "term-red"
        "32" "term-green"
        "33" "term-yellow"
        "90" "term-gray"))

;; Converts lines containing ANSI escapes to a list of content, one element per line. The current
;; styles carry over from one line to the next, as they do in a terminal.
(define (ansi-lines->content lines)
  (let loop ([lines lines] [classes '()] [acc '()])
    (cond
      [(null? lines) (reverse acc)]
      [else
       (define-values (content classes*) (ansi-line->content (car lines) classes))
       (loop (cdr lines) classes* (cons content acc))])))

;; Returns the line's content and the classes in effect at its end
(define (ansi-line->content line classes)
  (define codes (regexp-match-positions* #rx"\e\\(B|\e\\[([0-9;]*)m" line #:match-select values))
  (let loop ([pos 0] [codes codes] [classes classes] [acc '()])
    (define next (if (null? codes) (string-length line) (caar (car codes))))
    (define acc* (if (< pos next)
                     (cons (wrap classes (text->content (substring line pos next))) acc)
                     acc))
    (cond
      [(null? codes) (values (reverse acc*) classes)]
      [else
       (define code (car codes))
       (define params (and (cadr code) (substring line (car (cadr code)) (cdr (cadr code)))))
       (loop (cdr (car code)) (cdr codes) (apply-sgr params classes) acc*)])))

;; params is #f for an escape that doesn't change the style, such as ESC ( B
(define (apply-sgr params classes)
  (cond
    [(not params) classes]
    [else
     ;; ESC [ m, with no parameters, is a reset
     (for/fold ([classes classes]) ([p (in-list (if (string=? params "")
                                                    '("0")
                                                    (string-split params ";" #:trim? #f)))])
       (cond
         [(member p '("" "0")) '()]
         [(hash-ref sgr-classes p #f) => (λ (c) (remove-duplicates (cons c classes)))]
         [else classes]))]))

(define (wrap classes content)
  (for/fold ([content content]) ([c (in-list classes)])
    (styled c content)))
