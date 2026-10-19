#lang racket/base

(require "private/impl.rkt" "private/api.rkt")
(provide make-widget widget-size gadget
         (rename-out [make-widget build-widget] ; a second name for make-widget
                     [%frob frob]               ; also renamed in lite.rkt
                     [%color widget-color]))
