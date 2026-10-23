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
  (note nil)                            ; what was changed to fit the format
  (settings nil))                       ; the format and settings it was written with

(defun status-text (status)
  "The table's Status column: blank until converted."
  (ecase status
    ((nil) "")
    (:converting "converting…")
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
              (entry-settings entry) nil
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

(defun convert-entry (entry format &rest settings &key compression quality lossless)
  "Convert ENTRY, which PLAN-BATCH has given an output, to FORMAT with SETTINGS
(see CONVERT-FILE), and record how it went in its status, message and note.
Never signals; answers ENTRY.

The status is :CONVERTING meanwhile, and is set last, after the message and the
note: another thread -- the window, drawing the table -- may read ENTRY while
this runs, and an :OK or :ERROR it sees comes with what goes with it."
  (declare (ignore compression quality lossless))
  (setf (entry-message entry) nil (entry-note entry) nil
        (entry-settings entry) (apply #'settings-text (output-format-name format) settings)
        (entry-status entry) :converting)
  (let ((note nil) (message nil))
    (handler-case
        (let ((output (entry-output entry)))
          (cond ((null output)
                 (error "No output file was planned for this image."))
                ((or (string-equal output (entry-input entry))
                     (same-file-p output (entry-input entry)))
                 (error "The output would replace the original. Choose another output folder or format."))
                (t
                 (setf note (apply #'convert-file (entry-input entry) output
                                   (output-format-name format) settings))
                 (mark-converted output (entry-input entry)))))
      (error (condition)
        (setf message (without-paths (condition-text condition)
                                     (entry-input entry)
                                     (entry-output entry)))))
    (setf (entry-note entry) note
          (entry-message entry) message
          (entry-status entry) (if message :error :ok)))
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
     (when (entry-settings entry)
       (format out "As: ~a~%" (entry-settings entry)))
     (when (entry-message entry)
       (format out "~%Error: ~a~%" (entry-message entry)))
     (when (entry-note entry)
       (format out "~%~a~%" (entry-note entry))))))
;;; Converting a batch on several threads ---------------------------------------------
;;;
;;; The work is IM's, in C, and SBCL threads run foreign code in parallel, so a
;;; folder converts about as many times faster as there are cores.  Each worker
;;; takes the next entry and converts it; nothing else is shared but the run's
;;; own bookkeeping, under its lock, and IM's few static buffers, under
;;; *IM-LOCK* (formats.lisp).  Threads SBCL made, not Grand Central Dispatch's:
;;; a stock SBCL cannot stop GCD's threads for a garbage collection, and dies.
;;;
;;; The window learns of progress through ON-PROGRESS, called on the worker's
;;; thread after each file and when a worker finishes; it must not touch AppKit
;;; there, only ask the main thread to look (TAKE-FINISHED).

(defun processor-count ()
  "How many processors macOS is running work on now."
  (or (ignore-errors
       (cffi:with-foreign-objects ((count :int) (size :size))
         (setf (cffi:mem-ref size :size) (cffi:foreign-type-size :int))
         (and (zerop (cffi:foreign-funcall "sysctlbyname" :string "hw.activecpu"
                                           :pointer count :pointer size
                                           :pointer (cffi:null-pointer) :size 0 :int))
              (plusp (cffi:mem-ref count :int))
              (cffi:mem-ref count :int))))
      1))

(defvar *worker-count* nil
  "How many files are converted at once: NIL for one a processor.")

(defstruct (batch-run (:conc-name run-) (:constructor %make-batch-run))
  (entries #() :type vector)
  format
  (settings '())
  (next 0)                              ; the index handed out next
  (live 0)                              ; workers not yet finished
  (stopping nil)                        ; no more are handed out
  (finished '())                        ; indices done since TAKE-FINISHED
  (lock (sb-thread:make-mutex :name "batch run"))
  (threads '())
  (on-progress nil))

(defun prepare-output-folders (entries)
  "Make every output's folder before the workers start, so that two of them
never race to make the same one."
  (let ((made (make-hash-table :test #'equal)))
    (loop for entry across entries
          for output = (entry-output entry)
          for slash = (and output (position #\/ output :from-end t))
          when (and slash (not (gethash (subseq output 0 slash) made)))
            do (setf (gethash (subseq output 0 slash) made) t)
               (ignore-errors
                (ensure-directories-exist (sb-ext:parse-native-namestring
                                           (subseq output 0 (1+ slash))))))))

(defun start-batch (entries format &key settings on-progress
                                        (workers (or *worker-count* (processor-count))))
  "Convert ENTRIES, a vector PLAN-BATCH has planned, to FORMAT with SETTINGS on
WORKERS threads.  Answers the run at once; ON-PROGRESS, if given, is called with
it on a worker's thread after each file and as each worker ends."
  (let* ((entries (coerce entries 'vector))
         (run (%make-batch-run :entries entries :format format :settings settings
                               :on-progress on-progress))
         (count (max 1 (min workers (length entries)))))
    (loop for entry across entries
          do (setf (entry-status entry) nil (entry-message entry) nil
                   (entry-note entry) nil (entry-settings entry) nil))
    (prepare-output-folders entries)
    (setf (run-live run) (if (zerop (length entries)) 0 count))
    (when (plusp (length entries))
      (setf (run-threads run)
            (loop for i below count
                  collect (sb-thread:make-thread #'batch-worker
                                                 :name (format nil "convert ~d" i)
                                                 :arguments (list run)))))
    run))

(defun next-entry (run)
  "The index of the next entry to convert, or NIL when there are none or the
run is stopping."
  (sb-thread:with-mutex ((run-lock run))
    (let ((index (run-next run)))
      (unless (or (run-stopping run) (>= index (length (run-entries run))))
        (incf (run-next run))
        index))))

(defun notify (run)
  (let ((function (run-on-progress run)))
    (when function
      (ignore-errors (funcall function run)))))

(defun batch-worker (run)
  (unwind-protect
       (loop for index = (next-entry run)
             while index
             do (let ((entry (aref (run-entries run) index)))
                  ;; CONVERT-ENTRY handles every error a file can cause; this
                  ;; is for one it did not foresee, which must still leave the
                  ;; row answered and the worker going.
                  (handler-case (apply #'convert-entry entry (run-format run)
                                       (run-settings run))
                    (serious-condition (condition)
                      (setf (entry-message entry) (condition-text condition)
                            (entry-status entry) :error)))
                  (sb-thread:with-mutex ((run-lock run))
                    (push index (run-finished run)))
                  (notify run)))
    (sb-thread:with-mutex ((run-lock run))
      (decf (run-live run)))
    (notify run)))

(defun stop-batch (run)
  "Hand out no more files.  Those being converted are finished."
  (sb-thread:with-mutex ((run-lock run))
    (setf (run-stopping run) t)))

(defun batch-done-p (run)
  "Whether every worker has ended."
  (sb-thread:with-mutex ((run-lock run))
    (zerop (run-live run))))

(defun take-finished (run)
  "The indices of the entries finished since this was last asked, oldest first."
  (sb-thread:with-mutex ((run-lock run))
    (prog1 (nreverse (run-finished run))
      (setf (run-finished run) '()))))

(defun wait-for-batch (run &key timeout)
  "Wait for every worker to end, or TIMEOUT seconds.  True if they all did."
  (let ((deadline (and timeout (+ (get-internal-real-time)
                                  (* timeout internal-time-units-per-second)))))
    (dolist (thread (run-threads run) t)
      (let ((left (and deadline (/ (- deadline (get-internal-real-time))
                                   internal-time-units-per-second))))
        (when (and left (<= left 0))
          (return nil))
        (multiple-value-bind (result outcome)
            (sb-thread:join-thread thread :default nil :timeout left)
          (declare (ignore result))
          (when (eq outcome :timeout)
            (return nil)))))))
