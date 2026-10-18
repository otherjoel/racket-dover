#lang scribble/manual

@(require (for-label racket/base tally))

@title{Tally}

@defmodule[tally]

@defproc[(counter? [v any/c]) boolean?]{
Returns @racket[#t] if @racket[v] is a counter.}

@defproc[(make-counter) counter?]{
Returns a new counter whose value is 0.}

@defproc[(counter-add! [c counter?] [k exact-integer? 1]) void?]{
Adds @racket[k] to the value of @racket[c].}

@defproc[(tally [pred (-> any/c any/c)] [lst list?]) exact-nonnegative-integer?]{
Returns the number of elements of @racket[lst] for which @racket[pred] returns a true value.}
