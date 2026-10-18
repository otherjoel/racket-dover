#lang scribble/manual

@(require (for-label racket/base tally))

@title{Tally}

@defmodule[tally #:use-sources (tally/private/counter)]

@defproc[(counter? [v any/c]) boolean?]{
Returns @racket[#t] if @racket[v] is a counter.}

@defproc[(make-counter) counter?]{
Returns a new counter whose value is 0.}

@defproc[(counter-add! [c counter?] [k exact-integer? 1]) void?]{
Adds @racket[k] to the value of @racket[c].}

@defproc[(counter-value [c counter?]) exact-integer?]{
Returns the value of @racket[c].}

@defproc[(tally [pred (-> any/c any/c)] [lst list?]) exact-nonnegative-integer?]{
Returns the number of elements of @racket[lst] for which @racket[pred] returns a true value.}

@defform[(with-counter (id) body ...+)]{
Binds @racket[id] to a new counter, evaluates the @racket[body]s, and returns the counter's
final value.}
