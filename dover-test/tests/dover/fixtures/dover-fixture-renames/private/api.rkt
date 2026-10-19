#lang racket/base

;; Gives %gadget its public name, once, for both public modules that export it
(require "impl.rkt")
(provide (rename-out [%gadget gadget]))
