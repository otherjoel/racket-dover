#lang scribble/manual

@(require scribble/bnf
          "terminal.rkt"
          (for-label dover
                     racket/base
                     racket/contract
                     scribble/manual))

@title{Dover: Documentation Coverage}
@author{Joel Dueck}

Racket has an amazing documentation system in @seclink["plt-manuals" #:doc '(lib
"scribblings/scribble/scribble.scrbl")]{Scribble}, and if you’re making Racket packages, you should
use it.

Dover checks a set of one or more packages and scores them on how many of their exported bindings
have Scribble documentation. Use it from the command line while you write docs, or in CI to keep
coverage from slipping.

Installation:

@commandline{raco pkg install dover}

To use:

@commandline{raco dover check @nonterm{options} @nonterm{pkg} ...}

Dover reads the documentation that is already installed, so a package's docs must be built (normally
by @exec{raco pkg install} or @exec{raco setup}) before Dover can see them.

The canonical copy of this documentation is at @url{https://joeldueck.com/what-about/dover}.

@table-of-contents[]

@section[#:tag "tour"]{Quick tour}

Suppose you have written a small package called @tt{tally}:

@tour-tree["tally"]

The private module defines a counter:

@tour-file["tally/private/counter.rkt"]

The @racketmodfont{tally/base} module re-exports just the counter, and the main
@racketmodfont{tally} module re-exports @racketmodfont{tally/base} and adds two bindings of its own:

@tour-file["tally/base.rkt"]
@tour-file["tally/main.rkt"]

The package's docs cover most, but not all, of these bindings:

@tour-file["tally/scribblings/tally.scrbl"]

After installing the package, which also builds its docs, check it with @exec{raco dover check}:

@tour-output["check"]

Dover finds two bindings that have no documentation. Notice that it reports both under the
@racketmodfont{tally} module. One of those bindings, @racketidfont{with-counter}, is defined in
@filepath{tally/main.rkt}, so that makes sense. But the other one, @racketidfont{counter-value}, is
defined in the private module, then re-exported from @racketmodfont{tally/base} @emph{and} from
@racketmodfont{tally}. So how does Dover decide that the documentation for
@racketidfont{counter-value} belongs in the docs for the @racketmodfont{tally} module?

When the same binding comes from multiple places, Dover tries to be smart about which module it
reports it under. In this case it sees that we have already documented the other bindings from
@racketmodfont{tally/private/counter} (@racketidfont{counter?}, @racketidfont{make-counter} and
@racketidfont{counter-add!}) in the Scribble docs for @racketmodfont{tally}, and that the
undocumented @racketidfont{counter-value} is also exported from @racketmodfont{tally}. (See
@secref["grouping"].)

Additionally, there are warnings about the docs that @emph{do} already exist. They say that
@racketidfont{counter?}, @racketidfont{make-counter} and @racketidfont{counter-add!}, as exported by
@racketmodfont{tally/base}, don’t connect to their docs, so a program that requires
@racketmodfont{tally/base} gets no links to them. This is because the @racket[defproc] forms for
those bindings are inside a section that declares it is documenting bindings from
@racketmodfont{tally}, and @racketmodfont{tally/base} gets these bindings straight from the private
module without going through @racketmodfont{tally}. (See @secref["warnings"].)

To start on the missing documentation, you can ask for stubs using the @Flag{f} (or @DFlag{format})
flag and specifying @tt{stubs} as the output format:

@tour-output["stubs"]

The stubs are grouped by the module that each binding is reported under. Since @racketmodfont{tally}
already has docs, Dover doesn't start a new @racket[defmodule] for it, but suggests adding the stubs
under the existing @racket[defmodule]. It also suggests adding each stub near the docs for the
bindings defined in the same module: @racketidfont{counter-value} near the other counter functions,
and @racketidfont{with-counter} near @racketidfont{tally}. Since these differ, each gets its own
group, after a separator line.

Now we’ll fix the docs by adding the missing stubs and filling them in, and by adding the
@racket[#:use-sources] that the warnings suggest:

@tour-file["tally-fixed.scrbl"
           #:as "tally/scribblings/tally.scrbl"
           #:added-since "tally/scribblings/tally.scrbl"]

After rebuilding the docs, the check comes back clean:

@commandline{raco setup --pkgs tally}
@tour-output["check-fixed"]

@section{Checking a package}

@subsection[#:tag "raco-dover"]{@exec{raco dover check}}

@commandline{raco dover check @nonterm{options} @nonterm{pkg} ...}

For each installed @nonterm{pkg}, Dover finds the package's modules, collects the bindings they
export at phase 0, and looks each binding up in the installed documentation. It prints the bindings
that are missing documentation, grouped by module, followed by a coverage summary and any
@seclink["warnings"]{documentation warnings}.

Valid flags for @nonterm{options}:

@itemlist[
 @item{@DFlag{include-private} --- also check modules in @filepath{private} directories and
       modules listed in @racketidfont{dover-consider-private}.}
 @item{@DFlag{ignore} @nonterm{module} or @DFlag{ignore} @nonterm{module}@litchar{:}@nonterm{id}
       --- ignore every binding from @nonterm{module}, or just the binding @nonterm{id}. The
       @nonterm{module} can be any checked module that exports the binding, or the one that
       defines it.
       This flag can be given more than once.}
 @item{@DFlag{min} @nonterm{percent} --- exit with status 1 if coverage is below
       @nonterm{percent}. Overrides @racketidfont{dover-min-coverage}.}
 @item{@DFlag{strict} --- exit with status 1 if there are any
       @seclink["warnings"]{documentation warnings}.}
 @item{@DFlag{show-reexported} --- also list the bindings re-exported from other packages,
       which don't affect the score (see @secref["bindings"]). The JSON output always includes
       them.}
 @item{@Flag{f} @nonterm{format} or @DFlag{format} @nonterm{format} --- where @nonterm{format} is
 one of:

       @itemlist[
        @item{@exec{text} (the default) --- a human-readable report, in color when the output
              is a terminal. Set the @envvar{NO_COLOR} environment variable to turn color off,
              or @envvar{FORCE_COLOR} to turn it on for output that is not a terminal;}
        @item{@exec{json} --- a JSON object with totals per module (for scored bindings) or per
              package (for unscored ones), the missing bindings with the modules that export
              them, and the documentation warnings with their suggested fixes;}
        @item{@exec{stubs} --- a @racket[defproc] or @racket[defform] stub for each missing
              binding, ready to paste into a Scribble file and fill in. The stubs are grouped by
              the module they are reported under: under a new @racket[defmodule] if that module
              has no docs yet, or after a comment suggesting the existing @racket[defmodule]
              or @racket[declare-exporting] to add them under. Since a module's docs can span
              several sections, Dover also suggests adding each stub near the docs for other
              bindings defined in the same module, naming up to three of them. Stubs that get
              the same suggestion are listed together; when a module's stubs get different
              suggestions, each group comes after a separator line.}]}
]

@subsection[#:tag "modules"]{Which modules are checked}

By default, Dover checks every @filepath{.rkt} file in the package's collections, except:

@itemlist[
 @item{files in directories that are named @filepath{private}, @filepath{compiled} or
       @filepath{scribblings}, or whose names start with @litchar{.};}
 @item{@filepath{info.rkt} files and @filepath{lang/reader.rkt} modules;}
 @item{paths excluded by a @racketidfont{compile-omit-paths} field in any @filepath{info.rkt},
       since @exec{raco setup} does not compile them either.}
]

To treat other modules as private, list them in the @racketidfont{dover-consider-private} field
of @filepath{info.rkt}. Use this for internal modules that are not in a @filepath{private}
directory. Dover skips private modules, but still counts the bindings that checked modules
re-export from them.

Use @DFlag{include-private} to check all private modules too, or list specific private modules
that Dover should always check in the @racketidfont{dover-never-ignore} field of
@filepath{info.rkt}. To replace module discovery altogether, list the modules in
@racketidfont{dover-modules}.

Dover declares each module but does not instantiate it, so checking a package does not run its
code.

@subsection[#:tag "bindings"]{Which bindings count}

Dover follows each re-exported binding back to the module where it is originally defined, and
scores it according to which package that module belongs to:

@itemlist[
 @item{A binding defined in one of the packages being checked counts toward the score. This
       includes bindings defined in private modules and re-exported by public ones.}
 @item{A binding re-exported from another package does not affect the score. The text report
       lists these bindings, grouped by the package that defines them, only if you give
       @DFlag{show-reexported}.}
 @item{A binding re-exported from Racket's main collections (such as @racketmodname[racket/list])
       is skipped.}
]

A binding is counted once, however many checked modules export it. It is @deftech{documented} if
Scribble can find its documentation from at least one of those modules, and @deftech{missing}
otherwise. Only documented bindings count as covered.

@subsection[#:tag "grouping"]{Where bindings are reported}

Dover reports each scored binding under exactly one of the checked modules that export it:

@diagram["grouping.svg"]{Flowchart. For a scored binding: if it is documented and its docs name a
module that exports it, report it under the first such module. If it is missing and its siblings
(the documented bindings defined in the same module) are under a module that exports it, report it
under the module that most of them are under. Otherwise, report it under the checked module nearest
its definition. Ties go to the module that sorts first.}

@itemlist[
 
@item{A documented binding goes under the first module that its documentation says exports it (as
given by @racket[defmodule] or @racket[declare-exporting]) and that does export it. For example,
after @racket[(declare-exporting mypkg/element mypkg/core)], the bindings in that section are
reported under @racketmodfont{mypkg/element}.}

@item{A missing binding that has @deftech{siblings} (documented bindings defined in the same module)
is reported under the module that most of them are reported under, if that module also exports
it. So if @racketmodfont{mypkg/private/impl} defines
several bindings that are documented under @racketmodfont{mypkg}, a missing one that
@racketmodfont{mypkg} also exports is reported under @racketmodfont{mypkg}, next to the others.}

@item{Any other binding goes under the checked module nearest to its definition. If the
module that defines it is checked, that is the module; otherwise it is the first checked module that
re-exports it, working outward from the definition. So a missing binding defined in
@racketmodfont{mypkg/private/impl} and re-exported by @racketmodfont{mypkg/element} (which is in
turn re-exported by @racketmodfont{mypkg}) is reported under @racketmodfont{mypkg/element}, which is
probably where its documentation belongs.}

]

When two modules are equally near, or have equally many siblings, the one that sorts first wins.

@subsection[#:tag "warnings"]{Documentation warnings}

Besides missing documentation, Dover reports two problems with documented bindings, each with a
suggested fix. Warnings do not affect the coverage score, and they affect the exit status only
when you give @DFlag{strict}.

@itemlist[
 @item{@bold{Binding doesn’t connect to its docs.} A documented binding should connect to its
       documentation as exported by every checked module that exports it, so that a program
       requiring any of those modules gets links to the docs. To find the docs for a binding as
       exported by a module, Scribble follows its re-exports from that module toward the
       definition, looking for the module the docs are keyed to. If the docs use
       @racket[(defmodule mypkg/a)] but @racketmodfont{mypkg/b} re-exports the binding straight
       from the module that defines it, that path never passes through @racketmodfont{mypkg/a},
       so the binding as exported by @racketmodfont{mypkg/b} doesn’t connect to its docs.

       To fix it, add the defining module to the @racket[#:use-sources] of the
       @racket[defmodule] or @racket[declare-exporting], which keys the docs to the definition
       so that every re-export connects to them. See @secref["recipe-private"]. (Adding
       @racketmodfont{mypkg/b} to @racket[declare-exporting] does not help.) If
       @racketmodfont{mypkg/b} is an internal module that users should not require, list it in
       @racketidfont{dover-consider-private} instead.

       Scribble matches @racket[#:use-sources] modules by name, so when a binding is renamed on
       its way to a public module, Dover suggests the module on that path that exports it under
       the name the docs use. Two kinds of rename can’t be fixed that way:

       @itemlist[
        @item{If each public module gives the binding its public name itself, as with
              @racket[(provide (rename-out [%make-widget make-widget]))] in both
              @racketmodfont{mypkg/a} and @racketmodfont{mypkg/b}, no module between
              @racketmodfont{mypkg/b} and the definition exports it as
              @racketidfont{make-widget}. Give it
              that name in one module that both re-export it from, and add that module to the
              @racket[#:use-sources]; or have @racketmodfont{mypkg/b} re-export it from
              @racketmodfont{mypkg/a}.}
        @item{If @racketmodfont{mypkg/b} exports the binding under a different name than the
              docs use, that name needs its own docs, for example with @racket[deftogether].}]}

 @item{@bold{Incorrect export claim.} The docs say a checked module exports a binding (through
       @racket[defmodule] or @racket[declare-exporting]), but the module doesn't. Either remove
       the module from the declaration or export the binding from it.}
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

 @item{@racketidfont{dover-consider-private} --- a list of modules to treat as private, in
       addition to the modules in @filepath{private} directories. Dover does not check them unless
       @DFlag{include-private} is given, but bindings that checked modules re-export from them
       still count.

       @racketblock[
       (define dover-consider-private '(mypkg/components/email))
       ]

       Unlike @racketidfont{dover-ignore}, this does not remove any bindings from the check: a
       binding defined in @racketmodfont{mypkg/components/email} and re-exported by
       @racketmodfont{mypkg} is still counted, and still needs documentation.}

 @item{@racketidfont{dover-never-ignore} --- a list of modules that Dover always checks, even
       if they are in a @filepath{private} directory or listed in
       @racketidfont{dover-consider-private}.

       @racketblock[
       (define dover-never-ignore '(mypkg/private/public-api))
       ]}

 @item{@racketidfont{dover-modules} --- a list of the modules to check. When present, Dover skips
       module discovery and @racketidfont{dover-never-ignore} and checks exactly these
       modules, minus any in @racketidfont{dover-consider-private} (unless
       @DFlag{include-private} is given).}

 @item{@racketidfont{dover-min-coverage} --- a number from 0 to 100. When coverage is below it,
       @exec{raco dover check} exits with status 1. The @DFlag{min} flag overrides it.}
]

@subsection{Using Dover in CI}

After installing your package and building its docs, run:

@commandline{raco dover check --strict --min 100 mypkg-lib}

For a package split into @tt{-lib} and @tt{-doc} packages, check the package that contains the
modules, since that is where the bindings are defined. Install the @tt{-doc} package too, so that
its docs are built.

@include-section["recipe.scrbl"]

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
                     [exporters (listof exporter?)]
                     [doc-modules (or/c (listof module-path?) #f)])]{
A binding, identified by where it is defined. The @racket[module] and @racket[id] fields give the
module it is reported under (see @secref["grouping"]) and its name there. The
@racket[source-module] and @racket[source-id] fields give the module where it is defined and its
name there, and @racket[source-pkg] names the package containing @racket[source-module], or is
@racket[#f] for Racket's main collections. The @racket[exporters] field lists every checked module
that exports the binding.

The @racket[doc-modules] field is @racket[#f] if the binding is @tech{missing}. Otherwise it lists
the modules that the documentation says export the binding.}

@defstruct*[exporter ([module module-path?]
                      [id symbol?]
                      [via (listof (cons/c module-path? symbol?))]
                      [documented? boolean?])]{
A checked module’s export of a binding, under the name @racket[id]. A module that exports a binding
under more than one name has an @racket[exporter] for each name. The @racket[via] field lists the
modules, and the binding's names in them, that the binding passes through between @racket[module]
and the module that defines it. The @racket[documented?] field says whether the binding, as
exported by @racket[module] under @racket[id], connects to its documentation.}

@defproc[(binding-documented? [b binding?]) boolean?]{
Returns @racket[#t] if @racket[b] is @tech{documented}.}

@defstruct*[module-coverage ([module module-path?]
                             [documented (listof binding?)]
                             [missing (listof binding?)])]{
The bindings reported under @racket[module], divided into @tech{documented} and @tech{missing}.}

@defstruct*[doc-warning ([binding binding?] [module module-path?])]{
A @seclink["warnings"]{documentation warning} about @racket[binding] and @racket[module]. Only its
subtypes are instantiated.}

@defstruct*[(unreachable-docs-warning doc-warning) ([id symbol?]
                                                    [doc-id symbol?]
                                                    [use-source (or/c module-path? #f)])]{
The warning's binding is documented, but as exported by the warning's module under the name
@racket[id], it doesn't connect to its documentation. The @racket[doc-id] field is the name the
documentation uses for the binding. The @racket[use-source] field is a module on the binding’s
re-export path that exports it as @racket[doc-id], so that adding it to @racket[#:use-sources]
would connect this export to the documentation, or @racket[#f] if there is no such module.}

@defstruct*[(export-claim-warning doc-warning) ()]{
The documentation says the warning's module exports its binding, but the module doesn't.}

@defstruct*[coverage-report ([scored (listof module-coverage?)]
                             [unscored (listof module-coverage?)]
                             [warnings (listof doc-warning?)]
                             [errors (listof (cons/c module-path? string?))])]{
The result of @racket[check-coverage]. The @racket[scored] field covers bindings defined in the
checked packages, and @racket[unscored] covers bindings re-exported from other packages. The
@racket[warnings] field holds the documentation warnings for scored bindings. The @racket[errors]
field pairs each module that could not be loaded with its error message.}

@defproc[(package-modules [pkg string?]
                          [#:include-private? include-private? any/c #f])
         (listof module-path?)]{
Returns the modules in the installed package @racket[pkg], found as described in
@secref["modules"] but without any of the configuration from @filepath{info.rkt} other than
@racketidfont{compile-omit-paths}. Modules in @filepath{private} directories are included only if
@racket[include-private?] is true. The result is sorted so that each module comes before its
submodules and the modules nested under it.}

@defproc[(check-coverage [mods (listof module-path?)]
                         [#:packages pkgs (listof string?)]
                         [#:ignore ignore list? '()])
         coverage-report?]{
Checks the bindings exported by @racket[mods], declaring (but not instantiating) each module in a
fresh namespace. Bindings defined in one of @racket[pkgs] are scored; see @secref["bindings"].
Each element of @racket[ignore] has the same form as an element of @racketidfont{dover-ignore}.}

@defproc[(module-coverage-total [mc module-coverage?]) exact-nonnegative-integer?]{
Returns the number of bindings in @racket[mc], documented or not.}

@defproc[(coverage-ratio [mcs (listof module-coverage?)]) (or/c (between/c 0 1) #f)]{
Returns the fraction of the bindings in @racket[mcs] that are documented, or @racket[#f] if
@racket[mcs] contains no bindings.}

@;===============================================

@section{Acknowledgements}

@;------------------------------------------------

@define[url-1]{https://github.com/MarcKaufmann/congame/pull/173}
@define[url-2]{https://github.com/lexi-lambda/racket-commonmark/blob/master/commonmark-test/tests/commonmark/spec.rkt}
@define[url-3]{https://docs.racket-lang.org/doc-coverage/index.html}
@define[url-4]{https://www.visidata.org/blog/2026/ai/#self-assessed-ai-level-for-contributions}
@define[url-5]{https://github.com/otherjoel/racket-dover}

Dover is a cleaned-up generalization of a @hyperlink[url-1]{utility I wrote in 2025} for the Congame
project. I needed a quick way to check and score my progress on the documentation, and the module
layout was complicated. Dover itself is a @hyperlink[url-4]{level 6} AI-assisted rework of that
handwritten code.

The source for Dover is available at @tt{@url[url-5]}.

The code for the TUI progress bars was copied and adapted from Alexis King’s
@hyperlink[url-2]{CommonMark parser test suite}.

Jacqueline Firth’s @hyperlink[url-3]{Documentation Coverage} package also exists as prior art in
this area.

@bold{How do you pronounce “dover”? Is it like “over” or more like “cover”?}

@define[doverboys]{https://youtu.be/cDN0LKfurCw?si=vX4A6tnZrl9YkwS1&t=179}

@video-link[doverboys "hark.png" #:warning "smoking, alcohol"]{A still from the 1942 cartoon The
Dover Boys: Dan Backslide, half hidden in a cloud of smoke, says “Hark.”}
