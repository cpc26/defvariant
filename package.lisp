
(defpackage #:defvariant
  (:nicknames #:variant)
  (:use #:cl)
  (:export
   #:match-error
   #:defvariant
   #:match-error-message))

(in-package #:defvariant)

;; this is needed to disable to
;; inline example (only for top-level evaluations).
(defparameter *example-enabled* nil)

