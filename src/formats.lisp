;;;; formats.lisp -- the formats IM can write, as the drop-down shows them.
;;;;
;;;; Asked of IM each time rather than written down here: which formats exist
;;;; depends on which add-ons loaded (HEIF, AVIF and JP2 are optional), and that
;;;; is only known in the running application, not in the build.

(in-package #:image-converter)

(defstruct (output-format (:constructor %make-output-format))
  (name "" :type string)                ; IM's name: "PNG", "TIFF"
  (description "" :type string)         ; "Portable Network Graphic Format"
  (extensions '() :type list))          ; ("png"), first is the one written

(defun parse-extensions (string)
  "IM's \"*.tif;*.tiff;\" as (\"tif\" \"tiff\"), lower case."
  (loop with start = 0
        for end = (position #\; string :start start)
        for piece = (string-trim " " (subseq string start (or end (length string))))
        for name = (string-left-trim "*." piece)
        when (plusp (length name)) collect (string-downcase name)
        while end
        do (setf start (1+ end))))

(defun output-formats ()
  "Every format IM has registered, in IM's order."
  (loop for name in (im:format-list)
        for info = (ignore-errors (im:format-info name))
        when info
          collect (%make-output-format :name name
                                       :description (first info)
                                       :extensions (parse-extensions (second info)))))

(defun output-format-extension (format)
  "The extension written for FORMAT: the first IM lists, else its name."
  (or (first (output-format-extensions format))
      (string-downcase (output-format-name format))))

(defun output-format-title (format)
  "What the drop-down shows for FORMAT."
  (format nil "~a — ~a" (output-format-name format) (output-format-description format)))

(defun find-output-format (name &optional (formats (output-formats)))
  (find name formats :key #'output-format-name :test #'string-equal))

(defun image-extensions (&optional (formats (output-formats)))
  "Every extension of every registered format: what counts as an image file."
  (remove-duplicates (loop for format in formats
                           append (output-format-extensions format))
                     :test #'string=))
