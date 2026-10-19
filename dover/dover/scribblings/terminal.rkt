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
         tour-output
         tour-tree)

(define-runtime-path terminal-css "terminal.css")
(define-runtime-path tour-dir "tour/")

(define (styled class content)
  (element (style class (list (css-style-addition terminal-css))) content))

;; Shows a file from the sample package, or the fixed docs. Pass `as` to label it with a name
;; other than its path in tour/, and `added-since` to highlight what has been added since that
;; earlier version of the file.
(define (tour-file path #:as [label path] #:added-since [old-path #f])
  (define lines (read-code-lines path))
  (define added (if old-path (added-parts (read-code-lines old-path) lines) (hash)))
  ;; As codeblock does
  (define code (typeset-code #:indent 0 (string-join lines "\n")))
  (nested #:style (style "tour-file" (list (css-style-addition terminal-css) (alt-tag "div")))
          (filebox label (code-inset (highlight-rows code added)))))

;; Trimmed so that the file's final newline doesn't show as an empty line
(define (read-code-lines path)
  (string-split (string-trim (file->string (build-path tour-dir path)) #:left? #f)
                "\n" #:trim? #f))

;; Returns a hash from the index of each line in new that is not in old to the part of it that
;; is new: #t for the whole line, or (cons start end) for text inserted into an old line. Blank
;; lines are left out, so that the highlights show only the added code.
(define (added-parts old new)
  (define old-v (list->vector old))
  (define new-v (list->vector new))
  (for*/hash ([hunk (in-list (diff-hunks old-v new-v))]
              [(j k) (in-indexed (cdr hunk))]
              [line (in-value (vector-ref new-v j))]
              #:when (non-empty-string? (string-trim line))
              [part (in-value
                     (or (and (< k (length (car hunk)))
                              (insertion (vector-ref old-v (list-ref (car hunk) k)) line))
                         #t))])
    (values j part)))

;; Compares old and new (vectors of lines) by their longest common subsequence. Returns each run
;; of differing lines as a pair of the indexes of the lines removed from old and the indexes of
;; the lines added in new.
(define (diff-hunks old new)
  (define m (vector-length old))
  (define n (vector-length new))
  ;; lcs[i][j] is the length of the LCS of old[i..] and new[j..]
  (define lcs (for/vector ([_ (in-range (add1 m))]) (make-vector (add1 n) 0)))
  (define (lcs-ref i j) (vector-ref (vector-ref lcs i) j))
  (for* ([i (in-range (sub1 m) -1 -1)] [j (in-range (sub1 n) -1 -1)])
    (vector-set! (vector-ref lcs i) j
                 (if (equal? (vector-ref old i) (vector-ref new j))
                     (add1 (lcs-ref (add1 i) (add1 j)))
                     (max (lcs-ref (add1 i) j) (lcs-ref i (add1 j))))))
  (let loop ([i 0] [j 0] [removed '()] [added '()] [hunks '()])
    (define (end-hunk)
      (if (and (null? removed) (null? added))
          hunks
          (cons (cons (reverse removed) (reverse added)) hunks)))
    (cond
      [(and (= i m) (= j n)) (reverse (end-hunk))]
      [(and (< i m) (< j n) (equal? (vector-ref old i) (vector-ref new j)))
       (loop (add1 i) (add1 j) '() '() (end-hunk))]
      [(and (< i m) (or (= j n) (>= (lcs-ref (add1 i) j) (lcs-ref i (add1 j)))))
       (loop (add1 i) j (cons i removed) added hunks)]
      [else (loop i (add1 j) removed (cons j added) hunks)])))

;; If new is old with text inserted, returns the inserted text's (cons start end) in new, not
;; counting the spaces around it. Otherwise returns #f.
(define (insertion old new)
  (define (common-length ref-old ref-new limit)
    (for/sum ([k (in-range limit)]
              #:break (not (char=? (ref-old k) (ref-new k))))
      1))
  (define old-len (string-length old))
  (define new-len (string-length new))
  (define prefix (common-length (λ (k) (string-ref old k)) (λ (k) (string-ref new k))
                                (min old-len new-len)))
  (define suffix (common-length (λ (k) (string-ref old (- old-len k 1)))
                                (λ (k) (string-ref new (- new-len k 1)))
                                (- (min old-len new-len) prefix)))
  (and (= (+ prefix suffix) old-len)
       (< old-len new-len)
       (let loop ([start prefix] [end (- new-len suffix)])
         (cond
           [(and (< start end) (char=? (string-ref new start) #\space)) (loop (add1 start) end)]
           [(and (< start end) (char=? (string-ref new (sub1 end)) #\space)) (loop start (sub1 end))]
           [else (cons start end)]))))

;; typeset-code returns a table with a row for each line, holding a paragraph whose content is a
;; list of elements, one for each token
(define (highlight-rows code added)
  (define added-style (style "tour-added" (list (css-style-addition terminal-css))))
  (define (highlight-part content start end)
    (let loop ([content content] [pos 0])
      (cond
        [(null? content) '()]
        [else
         (define c (car content))
         (define len (string-length (content->string c)))
         (cons (if (and (positive? len) (< pos end) (> (+ pos len) start))
                   (element added-style c)
                   c)
               (loop (cdr content) (+ pos len)))])))
  (table (table-style code)
         (for/list ([row (in-list (table-blockss code))] [i (in-naturals)])
           (define part (hash-ref added i #f))
           (for/list ([cell (in-list row)])
             (cond
               [(not (and part (paragraph? cell))) cell]
               [(pair? part)
                (paragraph (paragraph-style cell)
                           (highlight-part (paragraph-content cell) (car part) (cdr part)))]
               [else (paragraph added-style (paragraph-content cell))])))))

;;================================================
;; Terminal output

;; Shows the command and output saved in tour/output/<name>.txt
(define (tour-output name)
  (define lines
    (file->lines (build-path tour-dir "output" (string-append name ".txt"))))
  (terminal (car lines) (cdr lines)))

;; Shows the files in tour/<dir> as `tree` run inside it would. This is computed rather than
;; captured, so it always matches the files and building the docs doesn't need `tree`.
(define (tour-tree dir)
  (define (plural n one many) (format "~a ~a" n (if (= n 1) one many)))
  ;; Returns the lines for d's contents and the numbers of directories and files in it
  (define (walk d prefix)
    (define names
      (sort (for/list ([p (in-list (directory-list d))]
                       #:unless (regexp-match? #rx"^[.]|^compiled$" (path->string p)))
              (path->string p))
            string<?))
    (for/fold ([lines '()] [dirs 0] [files 0]) ([name (in-list names)] [i (in-naturals)])
      (define last? (= i (sub1 (length names))))
      (define line (string-append prefix (if last? "└── " "├── ") name))
      (define p (build-path d name))
      (cond
        [(directory-exists? p)
         (define-values (sub-lines sub-dirs sub-files)
           (walk p (string-append prefix (if last? "    " "│   "))))
         (values (append lines (list line) sub-lines) (+ dirs 1 sub-dirs) (+ files sub-files))]
        [else (values (append lines (list line)) dirs (add1 files))])))
  (define-values (lines dirs files) (walk (build-path tour-dir dir) ""))
  ;; Like tree 2.x, the count includes the directory itself
  (terminal "tree"
            (append (list ".") lines
                    (list "" (string-append (plural (add1 dirs) "directory" "directories") ", "
                                            (plural files "file" "files"))))))

;; Shows a command and its output, which may contain ANSI escapes
(define (terminal cmd output-lines)
  (nested
   #:style (style "terminal" (list (css-style-addition terminal-css) (alt-tag "div")))
   (apply verbatim
          (add-between
           (cons (styled "term-prompt" (text->content cmd))
                 (ansi-lines->content
                  (append-map (λ (l) (wrap-ansi-line l terminal-width)) output-lines)))
           "\n"))))

;; Output lines wrap at this many characters, as in a terminal window of this width
(define terminal-width 80)

(define ansi-rx #rx"\e\\(B|\e\\[([0-9;]*)m")

;; Word-wraps line to at most width characters, not counting escape sequences. Continuation
;; lines are indented 4 more than the line's own indentation.
(define (wrap-ansi-line line width)
  ;; The positions in line of the characters that take up space
  (define visible
    (let loop ([pos 0] [acc '()])
      (cond
        [(= pos (string-length line)) (list->vector (reverse acc))]
        [(regexp-match-positions #rx"^(?:\e\\(B|\e\\[[0-9;]*m)" line pos)
         => (λ (m) (loop (cdar m) acc))]
        [else (loop (add1 pos) (cons pos acc))])))
  (define n (vector-length visible))
  (define indent (make-string (+ 4 (cdar (regexp-match-positions #rx"^ *" line))) #\space))
  ;; start: index into visible where this piece begins; room: characters available for it
  (let loop ([start 0] [raw-start 0] [room width] [prefix ""] [acc '()])
    (define (piece raw-end) (string-append prefix (substring line raw-start raw-end)))
    (cond
      [(<= (- n start) room) (reverse (cons (piece (string-length line)) acc))]
      [else
       ;; Break at the last space that fits, or in the middle of a word if there is none
       (define space
         (for/first ([i (in-range (+ start room) start -1)]
                     #:when (char=? (string-ref line (vector-ref visible i)) #\space))
           i))
       (define end (or space (+ start room)))
       (define next (if space (add1 space) end))
       (loop next (vector-ref visible next) (- width (string-length indent)) indent
             (cons (piece (vector-ref visible end)) acc))])))

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
        "3" "term-italic"
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
  (define codes (regexp-match-positions* ansi-rx line #:match-select values))
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
