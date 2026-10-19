#lang scribble/manual

@(require racket/runtime-path
          scribble/core
          scribble/html-properties
          "terminal.rkt"
          (for-label racket/base
                     scribble/manual))

@(define scribble-doc '(lib "scribblings/scribble/scribble.scrbl"))
@(define-runtime-path recipe-css "recipe.css")

@title[#:tag "recipe" #:style (style #f (list (css-style-addition recipe-css)))]{A recipe for
package docs}

Scribble can do a great deal, and @seclink["how-to-doc" #:doc scribble-doc]{its own documentation}
covers all of it. This section is the short version: the handful of forms you need to document the
modules in a typical package, in the order you’ll use them. Follow the links when you want the
details.

The recipe assumes you started your package with @exec{raco pkg new mypkg}. That gives you an
@filepath{info.rkt} that tells @exec{raco setup} to build your docs, and a starter document:

@filebox["mypkg/scribblings/mypkg.scrbl"]{
@codeblock|{
#lang scribble/manual
@require[@for-label[mypkg
                    racket/base]]

@title{mypkg}
@author{joel}

@defmodule[mypkg]

Package Description Here
}|}

@section{Step 1: Require your modules for-label}

The @racket[require] at the top of the document uses @racket[for-label]. This makes the bindings
from those modules available to your docs without running any of their code. Whenever you write the
name of a binding, whether in a @racket[defproc] or inside @racket[racket], Scribble uses these
bindings to work out which one you mean, and links the name to its documentation.

So the list should include every module whose bindings you document or mention: each of your
package’s public modules, @racketmodname[racket/base] (or @racketmodname[racket]), and any other
libraries you refer to. Names from a module you leave out still appear in your docs, but without
links. See @secref["racket-hyperlinks" #:doc scribble-doc] for more.

@section{Step 2: Start a section for each module}

Give each module that users can @racket[require] its own section, starting with @racket[defmodule]:

@codeblock[#:keep-lang-line? #f]|{
#lang scribble/manual
@section{Rendering}

@defmodule[mypkg/render]

Functions for turning widgets into HTML.
}|

The @racket[defmodule] form shows readers the @racket[require] line for the module. It also
declares that the bindings documented in the rest of the section are the ones exported by that
module, which is how Scribble connects your docs to the right bindings. Subsections inherit the
declaration, so you can split a module’s docs into as many subsections as you like.

If your package has just one module, the @racket[defmodule] at the top of the starter document is
all you need. See @secref["doc-modules" #:doc scribble-doc] for the options.

@section{Step 3: Document functions with @racket[defproc]}

Inside the module’s section, document each function with @racket[defproc]:

@codeblock[#:keep-lang-line? #f]|{
#lang scribble/manual
@defproc[(make-widget [name string?]
                      [size exact-positive-integer? 10]
                      [#:color color string? "blue"])
         widget?]{

Returns a new widget called @racket[name]. The @racket[size] is in
pixels.}
}|

The first part is a sample call: the function’s name, then each argument with its contract. An
optional argument adds its default value, and a keyword argument starts with its keyword. After
the sample call comes the contract for the result. Scribble typesets the contracts for readers but
doesn’t check them, so it’s up to you to keep them accurate.

The text in braces describes the function. When it refers to an argument, use @racket[racket], as
in @code|{@racket[name]}|, and Scribble will typeset it as an argument.

For structs, constants and parameters, use @racket[defstruct*], @racket[defthing] and
@racket[defparam], which work the same way. All of these are covered in
@secref["doc-forms" #:doc scribble-doc].

@section{Step 4: Document macros with @racket[defform]}

Document each macro with @racket[defform]:

@codeblock[#:keep-lang-line? #f]|{
#lang scribble/manual
@defform[(with-widget (id name-expr) body ...+)
         #:contracts ([name-expr string?])]{

Binds @racket[id] to a new widget called @racket[name-expr], then
evaluates the @racket[body]s.}
}|

Here the first part is a sample use of the form. Scribble takes the first identifier as the name of
the form, and typesets the others as placeholders for the pieces a user fills in. Use @racket[#:contracts]
to give contracts for the pieces that are expressions. For a form with a more complicated grammar,
use @racket[#:grammar], or see @racket[defform/subs].

@section{Step 5: Build and check}

Build your docs with @exec{raco setup}, then check them with Dover:

@commandline{raco setup --pkgs mypkg}
@commandline{raco dover check mypkg}

Dover lists the bindings that still need docs, and can give you a stub for each one to fill in.
See @secref["tour"] for an example.

@section[#:tag "recipe-reexports"]{When modules re-export each other}

It’s common for a package’s main module to re-export the bindings from its other public modules,
so that users can @racket[(require mypkg)] to get everything, or, for example, 
@racket[(require mypkg/render)] for just those functions.

If you document @racketidfont{render-page} under @racket[(defmodule mypkg/render)], it connects
to its docs as exported by either module. To find the docs for @racketidfont{render-page} as
exported by @racketmodfont{mypkg}, Scribble follows the re-export to @racketmodfont{mypkg/render}
and finds the docs there. But your docs only tell readers about one of the two: the box at the top of
@racketidfont{render-page}’s entry says it’s provided from @racketmodfont{mypkg/render}.

To list both modules, add @racket[#:no-declare] to the @racket[defmodule] and declare the modules
yourself with @racket[declare-exporting]:

@codeblock[#:keep-lang-line? #f]|{
#lang scribble/manual
@section{Rendering}

@defmodule[mypkg/render #:no-declare]
@declare-exporting[mypkg/render mypkg]
}|

The @racket[defmodule] still shows the @racket[require] line for @racketmodfont{mypkg/render}, and
the @racket[declare-exporting] declares both modules. Now @racketidfont{render-page} is provided
from @racketmodfont{mypkg/render} and @racketmodfont{mypkg}.

@diagram["reexport.svg"]{The mypkg module re-exports render-page from mypkg/render. The docs
are keyed to mypkg/render, and also list mypkg.}

The order of the modules matters. Scribble keys your docs to the binding as exported by the first
module, so list the module that defines the binding (or the one nearest to it) first. If you list
@racketmodfont{mypkg} first, the docs are keyed to @racketmodfont{mypkg}, and
@racketidfont{render-page} as exported by @racketmodfont{mypkg/render} doesn’t connect to them: the
binding doesn’t pass through @racketmodfont{mypkg} on its way there.

@section[#:tag "recipe-private"]{When public modules share a private module}

Another common pattern is to keep some code in a private module, and have more than one public module
re-export its bindings. Say @racketmodfont{mypkg} exports everything, and
@racketmodfont{mypkg/lite} exports just the basics, and each gets @racketidfont{make-widget} straight
from @racketmodfont{mypkg/private/widget}.

If you document @racketidfont{make-widget} under @racket[(defmodule mypkg)], it won’t connect to
its docs as exported by @racketmodfont{mypkg/lite}. To find the docs for @racketidfont{make-widget} as exported
by @racketmodfont{mypkg/lite}, Scribble follows its re-exports back toward the definition, looking
for the module the docs are keyed to. That path goes from @racketmodfont{mypkg/lite} to
@racketmodfont{mypkg/private/widget}, and never passes through @racketmodfont{mypkg}:

@diagram["private-before.svg"]{The docs are keyed to mypkg. Both mypkg and mypkg/lite
re-export make-widget from mypkg/private/widget, so make-widget as exported by mypkg/lite doesn’t
connect to its docs.}

Any docs that mention @racketidfont{make-widget} as imported from @racketmodfont{mypkg/lite},
including your own, end up with a broken link, and @exec{raco setup} warns about an undefined tag. Dover reports it
as a @seclink["warnings"]{documentation warning}.

The fix is @racket[#:use-sources], which keys the docs to the module that defines the binding:

@codeblock[#:keep-lang-line? #f]|{
#lang scribble/manual
@defmodule[mypkg #:use-sources (mypkg/private/widget)]
}|

Every re-export leads back to the definition, so now @racketidfont{make-widget} connects to its
docs as exported by any module that re-exports it:

@diagram["private-after.svg"]{The docs are keyed to mypkg/private/widget, where make-widget
is defined, so make-widget connects to them as exported by both mypkg and mypkg/lite.}

This works because the private module exports the binding under the same name the docs use.
Scribble matches the modules in @racket[#:use-sources] by name, so if
@racketmodfont{mypkg/private/widget} defined @racketidfont{%make-widget}, and each public module
renamed it with @racket[rename-out], no @racket[#:use-sources] could connect it. In that case, give
the binding its public name in one private module, have the public modules re-export it from
there, and add that module to @racket[#:use-sources].

The @racket[#:use-sources] option fixes the connection; it doesn’t change which modules your docs say
the binding is provided from. To list @racketmodfont{mypkg/lite} there too, combine it with the
approach from @secref["recipe-reexports"]:

@codeblock[#:keep-lang-line? #f]|{
#lang scribble/manual
@defmodule[mypkg #:no-declare]
@declare-exporting[mypkg mypkg/lite #:use-sources (mypkg/private/widget)]
}|

Since @racket[#:use-sources] decides where the docs are keyed, the order of
@racketmodfont{mypkg} and @racketmodfont{mypkg/lite} matters less here; put the one you’d most like
readers to use first. The docs for @racket[declare-exporting] explain how Racket’s own docs use
this for bindings like @racket[parameterize].
