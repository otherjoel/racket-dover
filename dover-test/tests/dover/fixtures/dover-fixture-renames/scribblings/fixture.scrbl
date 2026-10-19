#lang scribble/manual

@(require (for-label racket/base dover-fixture-renames))

@title{Renames fixture}

@defmodule[dover-fixture-renames]

@defproc[(make-widget) any/c]{Makes a widget.}
@defproc[(widget-size [w any/c]) any/c]{Its size.}
@defproc[(widget-color [w any/c]) any/c]{Its color.}
@defproc[(frob [w any/c]) any/c]{Frobs it.}
@defproc[(gadget) any/c]{Makes a gadget.}
