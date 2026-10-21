;;;; package.lisp

(defpackage #:image-converter
  (:use #:common-lisp)
  (:export
   ;; formats
   #:output-format #:output-format-name #:output-format-description
   #:output-format-extensions #:output-format-extension #:output-format-title
   #:output-formats #:find-output-format #:image-extensions
   ;; scanning
   #:scan-directory #:image-file-p #:relative-name
   ;; converting
   #:convert-file
   ;; the batch
   #:entry #:make-entry #:entry-input #:entry-relative #:entry-output
   #:entry-status #:entry-message #:entry-note
   #:plan-batch #:convert-entry #:entry-details #:status-text
   ;; the application
   #:main))
