;;;; batch.lisp -- the list of files, where each one goes, and how it went.
;;;;
;;;; This is what the window's table shows, one entry a row.  Nothing here
;;;; knows about the window, which is what lets the tests drive it directly.

(in-package #:image-converter)

(defstruct entry
  (input "" :type string)               ; native path of the source
  (relative "" :type string)            ; INPUT relative to the input folder
  (output nil)                          ; native path written, once planned
  (status nil)                          ; NIL, :OK or :ERROR
  (message nil)                         ; why it failed
  (note nil))                           ; what was changed to fit the format

(defun status-text (status)
  "The table's Status column: blank until converted."
  (ecase status
    ((nil) "")
    (:ok "ok")
    (:error "error")))

(defun strip-extension (relative)
  (let* ((slash (position #\/ relative :from-end t))
         (dot (position #\. relative :from-end t)))
    (if (and dot (> dot (if slash (1+ slash) 0)))
        (subseq relative 0 dot)
        relative)))

(defun plan-batch (entries output-directory format)
  "Give each of ENTRIES the path it is to be written to, in OUTPUT-DIRECTORY
and below it in the same subfolders as it was found in, named for FORMAT.

Two inputs that would land on one output -- photo.png and photo.jpg, both to
TIFF -- keep their old extension in the name, photo-png.tif and photo-jpg.tif,
rather than one silently replacing the other.  The same goes for an output that
would land on an input, so an input is never written over: photo.png to PNG in
its own folder is written as photo-png.png.
Answers ENTRIES, with any status from an earlier run cleared."
  (let ((extension (output-format-extension format))
        (directory (concatenate 'string
                                (string-right-trim "/" (canonical-path output-directory)) "/"))
        (counts (make-hash-table :test #'equal)))
    (flet ((target (entry &optional with-old-extension)
             (let ((stem (strip-extension (entry-relative entry))))
               (format nil "~a~a~@[-~a~].~a" directory stem
                       (and with-old-extension (file-extension (entry-input entry)))
                       extension))))
      ;; The inputs are taken names too, for when the output folder is the
      ;; input folder: photo.jpg to PNG must not land on the photo.png beside it.
      (dolist (entry entries)
        (incf (gethash (string-downcase (entry-input entry)) counts 0))
        (incf (gethash (string-downcase (target entry)) counts 0)))
      (dolist (entry entries)
        (setf (entry-status entry) nil
              (entry-message entry) nil
              (entry-note entry) nil
              (entry-output entry)
              (if (> (gethash (string-downcase (target entry)) counts) 1)
                  (target entry t)
                  (target entry))))))
  entries)

(defun same-file-p (a b)
  "Whether native paths A and B name one file.  The file system is commonly
case-insensitive, so Photo.PNG and photo.png are one."
  (let ((a (ignore-errors (truename (sb-ext:parse-native-namestring a))))
        (b (ignore-errors (truename (sb-ext:parse-native-namestring b)))))
    (and a b (equal (native a) (native b)))))

(defun convert-entry (entry format)
  "Convert ENTRY, which PLAN-BATCH has given an output, to FORMAT, and record
how it went in its status, message and note.  Never signals; answers ENTRY."
  (setf (entry-status entry) nil (entry-message entry) nil (entry-note entry) nil)
  (handler-case
      (let ((output (entry-output entry)))
        (cond ((null output)
               (error "No output file was planned for this image."))
              ((or (string-equal output (entry-input entry))
                   (same-file-p output (entry-input entry)))
               (error "The output would replace the original. Choose another output folder or format."))
              (t
               (setf (entry-note entry)
                     (convert-file (entry-input entry) output (output-format-name format))
                     (entry-status entry) :ok))))
    (error (condition)
      (setf (entry-status entry) :error
            (entry-message entry) (without-paths (condition-text condition)
                                                 (entry-input entry)
                                                 (entry-output entry)))))
  entry)

(defun without-paths (message &rest paths)
  "MESSAGE less a trailing \": <path>.\" naming one of PATHS.  IM ends each
error with the file's path, which the details already show above it."
  (dolist (path (remove nil paths) message)
    (let ((suffix (format nil ": ~a." path)))
      (when (and (> (length message) (length suffix))
                 (string= suffix message :start2 (- (length message) (length suffix))))
        (return (concatenate 'string (subseq message 0 (- (length message) (length suffix)))
                             "."))))))

(defun condition-text (condition)
  "CONDITION's report, or its type if the report itself fails."
  (or (ignore-errors (princ-to-string condition))
      (format nil "~a" (type-of condition))))

(defun entry-details (entry)
  "What double-clicking ENTRY shows: a title and the text beneath it."
  (values
   (case (entry-status entry)
     (:ok (format nil "~a was converted." (entry-relative entry)))
     (:error (format nil "~a could not be converted." (entry-relative entry)))
     (t (format nil "~a has not been converted yet." (entry-relative entry))))
   (with-output-to-string (out)
     (format out "From: ~a~%" (entry-input entry))
     (when (entry-output entry)
       (format out "To: ~a~%" (entry-output entry)))
     (when (entry-message entry)
       (format out "~%Error: ~a~%" (entry-message entry)))
     (when (entry-note entry)
       (format out "~%~a~%" (entry-note entry))))))
