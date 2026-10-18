#lang info

(define raco-commands
  '(("dover" (submod dover/private/raco main) "Scribble documentation tools" #f)))

(define dover-subcommands
  '(("check" dover/private/check "Report exported bindings that have no Scribble documentation")))
