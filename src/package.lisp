;;;; package.lisp

(defpackage #:image-converter
  (:use #:common-lisp)
  (:export
   ;; formats
   #:output-format #:output-format-name #:output-format-description
   #:output-format-extensions #:output-format-extension #:output-format-title
   #:input-formats #:output-formats #:find-output-format #:image-extensions
   ;; scanning
   #:scan-directory #:image-file-p #:relative-name
   #:mark-converted #:converted-from #:without-earlier-conversions
   ;; converting
   #:convert-file #:compression-choices #:quality-attribute #:lossless-available-p
   #:apply-settings #:settings-text
   ;; the batch
   #:entry #:make-entry #:entry-input #:entry-relative #:entry-output
   #:entry-status #:entry-message #:entry-note #:entry-settings
   #:plan-batch #:convert-entry #:entry-details #:status-text
   #:start-batch #:stop-batch #:batch-done-p #:take-finished #:wait-for-batch
   #:batch-run #:processor-count #:*worker-count*
   ;; the application
   #:main))
