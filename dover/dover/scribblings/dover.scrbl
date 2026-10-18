#lang scribble/manual

@(require scribble/bnf
          (for-label dover
                     racket/base
                     racket/contract))

@title{Dover: Documentation Coverage}
@author{Joel Dueck}

Dover checks which bindings exported by a package's modules have no Scribble documentation. Use it
from the command line while you write docs, or in CI to keep coverage from slipping.

Dover reads the documentation that is already installed, so a package's docs must be built
(normally by @exec{raco pkg install} or @exec{raco setup}) before Dover can see them.

@table-of-contents[]

@section{Checking a package}

@commandline{raco dover check @nonterm{pkg} ...}

For each installed @nonterm{pkg}, Dover finds the package's modules, collects the bindings they
export at phase 0, and looks each binding up in the installed documentation. It prints the bindings
that are missing documentation, grouped by module, followed by a coverage summary.

@subsection[#:tag "modules"]{Which modules are checked}

By default, Dover checks every @filepath{.rkt} file in the package's collections, except:

@itemlist[
 @item{files in directories named @filepath{private}, @filepath{compiled} or
       @filepath{scribblings}, or whose name starts with @litchar{.};}
 @item{@filepath{info.rkt} files and @filepath{lang/reader.rkt} modules;}
 @item{paths excluded by a @racketidfont{compile-omit-paths} field in any @filepath{info.rkt},
       since @exec{raco setup} does not compile them either.}
]

Use @DFlag{include-private} to check modules in @filepath{private} directories too, or list
specific private modules in the @racketidfont{dover-include-private} field of @filepath{info.rkt}. To
replace module discovery altogether, list the modules in @racketidfont{dover-modules}.

Dover declares each module but does not instantiate it, so checking a package does not run its
code.

@subsection[#:tag "bindings"]{Which bindings count}

Dover follows each re-exported binding back to the module where it is originally defined, and
scores it according to which package that module belongs to:

@itemlist[
 @item{A binding defined in one of the packages being checked counts toward the score. This
       includes bindings defined in private modules and re-exported by public ones.}
 @item{A binding re-exported from another package is listed separately, grouped by the package
       that defines it, and does not affect the score.}
 @item{A binding re-exported from Racket's main collections (such as @racketmodname[racket/list])
       is skipped.}
]

Scored bindings are reported under the module that exports them. When more than one checked module
exports the same binding, it is counted once, under the first module in sorted order. Since a module sorts before the modules nested under it, a binding exported
by both @racketidfont{mypkg} and @racketidfont{mypkg/util} is reported under
@racketidfont{mypkg}.

Each binding gets one of three statuses:

@itemlist[
 @item{@racket['documented] --- Scribble can find documentation for the binding from the module
       that exports it.}
 @item{@racket['unreachable] --- Scribble can find documentation for the binding from one of the
       modules it passes through on the way from its definition, but not from the module that
       exports it. This usually means the docs use @racket[defmodule] for a different module than
       the one users require. Only documented bindings count as covered.}
 @item{@racket['missing] --- no documentation was found.}
]

@subsection{Command-line flags}

@itemlist[
 @item{@DFlag{include-private} --- also check modules in @filepath{private} directories.}
 @item{@DFlag{ignore} @nonterm{module} or @DFlag{ignore} @nonterm{module}@litchar{:}@nonterm{id}
       --- ignore every binding from @nonterm{module}, or just the binding @nonterm{id}. The
       @nonterm{module} can be either the module that exports the binding or the one that defines
       it. This flag can be given more than once.}
 @item{@DFlag{min} @nonterm{percent} --- exit with status 1 if coverage is below
       @nonterm{percent}. Overrides @racketidfont{dover-min-coverage}.}
 @item{@Flag{f} @nonterm{format} or @DFlag{format} @nonterm{format} --- choose the output:
       @itemlist[
        @item{@exec{text} (the default) --- a human-readable report;}
        @item{@exec{json} --- a JSON object with totals per module (for scored bindings) or per
              package (for unscored ones), the bindings that are missing or unreachable, and any
              warnings;}
        @item{@exec{stubs} --- a @racket[defproc] or @racket[defform] stub for each missing
              binding, grouped under a @racket[defmodule] for its module, ready to paste into a
              Scribble file and fill in.}]}
]

@subsection{Configuration in @filepath{info.rkt}}

Dover reads the following fields from the package's top-level @filepath{info.rkt}. All are
optional.

@itemlist[
 @item{@racketidfont{dover-ignore} --- a list of bindings to leave out of the check. Each element
       is either a module path, which ignores every binding exported from or defined in that
       module, or a list of a module path followed by identifiers, which ignores only those
       identifiers.

       @racketblock[
       (define dover-ignore
         '(mypkg/tests
           (mypkg/form ~error ~errors)))
       ]

       Typical candidates are bindings that exist only to produce better syntax errors, and
       internals that are exported for use by other modules in the same package.}

 @item{@racketidfont{dover-include-private} --- a list of modules in @filepath{private}
       directories to check anyway.

       @racketblock[
       (define dover-include-private '(mypkg/private/public-api))
       ]}

 @item{@racketidfont{dover-modules} --- a list of the modules to check. When present, Dover skips
       module discovery and @racketidfont{dover-include-private} and checks exactly these
       modules.}

 @item{@racketidfont{dover-min-coverage} --- a number from 0 to 100. When coverage is below it,
       @exec{raco dover check} exits with status 1. The @DFlag{min} flag overrides it.}
]

@subsection{Using Dover in CI}

After installing your package and building its docs, run:

@commandline{raco dover check --min 100 mypkg-lib}

For a package split into @filepath{-lib} and @filepath{-doc} packages, check the package that
contains the modules, since that is where the bindings are defined.

@section{Library}

@defmodule[dover]

The @racketmodname[dover] module provides the functions that @exec{raco dover check} is built
on.

@defstruct*[binding ([module module-path?]
                     [id symbol?]
                     [kind (or/c 'value 'syntax)]
                     [source-module module-path?]
                     [source-id symbol?]
                     [source-pkg (or/c string? #f)]
                     [via (listof (cons/c module-path? symbol?))])]{
An exported binding. The @racket[module] and @racket[id] fields give the module that exports the
binding and the name it is exported under. The @racket[source-module] and @racket[source-id] fields
give the module where it is defined and its name there, and @racket[source-pkg] names the package
containing @racket[source-module], or is @racket[#f] for Racket's main collections. The
@racket[via] field lists the modules, and the binding's names in them, that the binding passes
through between @racket[module] and @racket[source-module].}

@defstruct*[module-coverage ([module module-path?]
                             [documented (listof binding?)]
                             [unreachable (listof binding?)]
                             [missing (listof binding?)])]{
The bindings exported from @racket[module], sorted by status. See @racket[binding-doc-status].}

@defstruct*[coverage-report ([scored (listof module-coverage?)]
                             [unscored (listof module-coverage?)]
                             [errors (listof (cons/c module-path? string?))])]{
The result of @racket[check-coverage]. The @racket[scored] field covers bindings defined in the
checked packages, and @racket[unscored] covers bindings re-exported from other packages. The
@racket[errors] field pairs each module that could not be loaded with the error message.}

@defproc[(package-modules [pkg string?]
                          [#:include-private? include-private? any/c #f])
         (listof module-path?)]{
Returns the modules in the installed package @racket[pkg], following the rules in
@secref["modules"], sorted so that each module comes before the modules nested
under it.}

@defproc[(module-bindings [mod module-path?]) (listof binding?)]{
Declares @racket[mod] in the current namespace, without instantiating it, and returns the bindings
it exports at phase 0. Raises an exception if @racket[mod] cannot be found or loaded.}

@defproc[(binding-doc-status [b binding?]) (or/c 'documented 'unreachable 'missing)]{
Looks @racket[b] up in the installed documentation. See @secref["bindings"] for the
meaning of each result.}

@defproc[(check-coverage [mods (listof module-path?)]
                         [#:packages pkgs (listof string?)]
                         [#:ignore ignore list? '()])
         coverage-report?]{
Checks the bindings exported by @racket[mods] in a fresh namespace. Bindings defined in one of
@racket[pkgs] are scored; see @secref["bindings"]. Each element of @racket[ignore] has
the same form as an element of @racketidfont{dover-ignore}.}

@defproc[(module-coverage-total [mc module-coverage?]) exact-nonnegative-integer?]{
Returns the number of bindings in @racket[mc], whatever their status.}

@defproc[(coverage-ratio [mcs (listof module-coverage?)]) (or/c (between/c 0 1) #f)]{
Returns the fraction of the bindings in @racket[mcs] that are documented, or @racket[#f] if
@racket[mcs] contains no bindings.}
