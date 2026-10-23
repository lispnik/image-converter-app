;;;; formats.lisp -- the formats IM can write, as the drop-down shows them.
;;;;
;;;; Asked of IM rather than written down here: which formats exist depends on
;;;; which add-ons loaded (HEIF, AVIF and JP2 are optional), and that is only
;;;; known in the running application, not in the build.  Asked once a process,
;;;; though, and kept: IM answers in static buffers, which a second thread
;;;; asking at the same time overwrites (see *IM-LOCK*).

(in-package #:image-converter)

;;; IM's shared state ---------------------------------------------------------------
;;;
;;; Files are converted on several threads at once (batch.lisp), and IM is safe
;;; for that except in three places, all found by converting the same files on
;;; one thread and on eight and comparing the bytes:
;;;
;;;   - imFormatList and imFormatCompressions answer in static buffers.  Read
;;;     once, under the lock, and cached: FORMAT-COMPRESSIONS* below.
;;;   - The RGB to palette quantizer (im_rgb2map.cpp) keeps its histogram,
;;;     colour map and error arrays in statics.  Under the lock: RESHAPE.
;;;   - The PNG writer counts the text chunks it writes in a static, and two
;;;     writers at once index past the end of their array.  Under the lock:
;;;     WRITE-SHAPE.
;;;
;;; The counter (im_counter.cpp) is shared too, but does nothing without a
;;; callback, and this application never sets one.

(defvar *im-lock* (sb-thread:make-mutex :name "IM's static buffers")
  "Held around every call into IM that uses one of its static buffers.")

(defmacro with-im-lock (() &body body)
  `(sb-thread:with-recursive-lock (*im-lock*) ,@body))

(defvar *output-formats* nil
  "OUTPUT-FORMATS, once asked.")

(defvar *format-compressions* (make-hash-table :test #'equalp)
  "Each format's compressions, as IM lists them, once asked.")

(defun forget-formats ()
  "Empty the caches, so that a saved image asks again: the bundle's IM may
have formats the build's had not."
  (with-im-lock ()
    (setf *output-formats* nil)
    (clrhash *format-compressions*)))

(pushnew 'forget-formats sb-ext:*save-hooks*)

(defun format-compressions* (format-name)
  "IM's compressions for FORMAT-NAME, from the cache."
  (with-im-lock ()
    (multiple-value-bind (compressions found) (gethash format-name *format-compressions*)
      (if found
          compressions
          (setf (gethash format-name *format-compressions*)
                (copy-list (ignore-errors (im:format-compressions format-name))))))))

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
  (with-im-lock ()
    (or *output-formats*
        (setf *output-formats*
              (loop for name in (im:format-list)
                    for info = (ignore-errors (im:format-info name))
                    when info
                      collect (%make-output-format
                               :name (copy-seq name)
                               :description (copy-seq (first info))
                               :extensions (parse-extensions (second info))))))))

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
