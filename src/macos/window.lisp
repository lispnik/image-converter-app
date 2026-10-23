;;;; window.lisp -- the window: the options, the list of files, Convert.
;;;;
;;;; One controller is the target of every control and the table's data source
;;;; and delegate.  What the table shows is a vector of ENTRYs (batch.lisp); a
;;;; change to any option scans the input folder again and plans where each
;;;; file is to go.
;;;;
;;;; Converting runs on worker threads, one file each at a time (START-BATCH,
;;;; batch.lisp).  The workers touch neither AppKit nor the Objective-C bridge:
;;;; the main thread looks ten times a second at what they have finished,
;;;; redraws, and logs it.  Stop hands out no more files and lets the ones
;;;; being converted finish.

(in-package #:image-converter)

(objc:define-objc-class window-controller ()
  ((window :initform nil :accessor controller-window)
   (input-field :initform nil :accessor controller-input-field)
   (output-field :initform nil :accessor controller-output-field)
   (recursive-checkbox :initform nil :accessor controller-recursive-checkbox)
   (format-popup :initform nil :accessor controller-format-popup)
   (compression-popup :initform nil :accessor controller-compression-popup)
   (compression-names :initform '() :accessor controller-compression-names
                      :documentation "The compression of each item in its drop-down,
NIL for Default.")
   (quality-slider :initform nil :accessor controller-quality-slider)
   (quality-label :initform nil :accessor controller-quality-label)
   (lossless-checkbox :initform nil :accessor controller-lossless-checkbox)
   (format-settings :initform (make-hash-table :test #'equalp)
                    :accessor controller-format-settings
                    :documentation "Each format's settings, by its name, as a plist
of :COMPRESSION, :QUALITY and :LOSSLESS: what the settings row shows for it.")
   (table :initform nil :accessor controller-table)
   (status-label :initform nil :accessor controller-status-label)
   (convert-button :initform nil :accessor controller-convert-button)
   (option-controls :initform '() :accessor controller-option-controls
                    :documentation "What cannot be changed while converting.")
   (formats :initform '() :accessor controller-formats
            :documentation "The OUTPUT-FORMATs, in the drop-down's order.")
   (entries :initform #() :accessor controller-entries
            :documentation "The table's rows.")
   (running :initform nil :accessor controller-running)
   (run :initform nil :accessor controller-run
        :documentation "The BATCH-RUN converting, while running.")
   (stopping :initform nil :accessor controller-stopping
             :documentation "Stop was pressed, and the files in hand are being finished.")
   (message :initform nil :accessor controller-message
            :documentation "Something to say in place of the count of files.")
   (skipped :initform 0 :accessor controller-skipped
            :documentation "How many files in the folder an earlier run wrote,
and so are not listed."))
  (:objc-class-name "ImageConverterWindowController"))

(defmacro define-controller-method ((selector result-type &key on-error)
                                    (&rest arguments) &body body)
  "A method of the controller.  Nothing may unwind into AppKit, so whatever
BODY signals is logged and ON-ERROR is answered instead."
  `(objc:define-objc-method (,selector ,result-type)
       ((self window-controller) ,@arguments)
     (declare (ignorable self ,@(mapcar #'first arguments)))
     (handler-case (progn ,@body)
       (error (condition)
         (note "~a: ~a" ,selector condition)
         ,on-error))))

;;; Settings ------------------------------------------------------------------------
;;;
;;; Kept in the user defaults, so the window opens as it was left.

(defvar *remember-settings* t
  "Whether the options are read from and written to the user defaults.  The
tests bind it to NIL, so as not to change the settings of whoever runs them.")

(defun user-defaults ()
  (objc:invoke "NSUserDefaults" "standardUserDefaults"))

(defun default-string (key)
  (and *remember-settings*
       (objc:invoke-into 'string (user-defaults) "stringForKey:" key)))

(defun default-bool (key)
  (and *remember-settings*
       (objc:invoke-bool (user-defaults) "boolForKey:" key)))

(defun save-settings (controller)
  (when *remember-settings*
    (let ((defaults (user-defaults))
          (format (selected-format controller)))
      (objc:invoke defaults "setObject:forKey:" (input-path controller) "InputFolder")
      (objc:invoke defaults "setObject:forKey:" (output-path controller) "OutputFolder")
      (objc:invoke defaults "setBool:forKey:" (recursive-p controller) "IncludeSubfolders")
      (when format
        (objc:invoke defaults "setObject:forKey:" (output-format-name format) "OutputFormat")))))

;;; Reading the options ---------------------------------------------------------------

(defun field-string (field)
  (or (objc:invoke-into 'string field "stringValue") ""))

(defun expand-path (string)
  "STRING as a native path: trimmed, ~ expanded, and with no trailing slash."
  (let ((path (string-trim '(#\Space #\Tab #\Newline) string)))
    (when (and (plusp (length path)) (char= #\~ (char path 0))
               (or (= 1 (length path)) (char= #\/ (char path 1))))
      (setf path (concatenate 'string
                              (string-right-trim "/" (native (user-homedir-pathname)))
                              (subseq path 1))))
    (if (and (> (length path) 1) (char= #\/ (char path (1- (length path)))))
        (string-right-trim "/" path)
        path)))

(defun abbreviate-path (path)
  "PATH with the home folder written ~, as the path fields show it."
  (let ((home (string-right-trim "/" (native (user-homedir-pathname)))))
    (if (and (>= (length path) (length home))
             (string= home path :end2 (length home))
             (or (= (length path) (length home)) (char= #\/ (char path (length home)))))
        (concatenate 'string "~" (subseq path (length home)))
        path)))

(defun input-path (controller)
  (expand-path (field-string (controller-input-field controller))))

(defun output-path (controller)
  (expand-path (field-string (controller-output-field controller))))

(defun recursive-p (controller)
  (= 1 (objc:invoke (controller-recursive-checkbox controller) "state")))

(defun selected-format (controller)
  (let ((index (objc:invoke (controller-format-popup controller) "indexOfSelectedItem")))
    (and (<= 0 index) (nth index (controller-formats controller)))))

(defun select-format (controller name)
  "Choose the format called NAME in the drop-down.  True if there is one."
  (let ((index (position name (controller-formats controller)
                         :key #'output-format-name :test #'string-equal)))
    (when index
      (objc:invoke (controller-format-popup controller) "selectItemAtIndex:" index)
      (show-format-settings controller)
      t)))

(defun directory-exists-p (path)
  (and (plusp (length path))
       (uiop:directory-exists-p (directory-name path))
       t))

;;; Showing the files -----------------------------------------------------------------

(defun count-status (controller status)
  (count status (controller-entries controller) :key #'entry-status))

(defun status-line (controller)
  (let* ((entries (controller-entries controller))
         (total (length entries))
         (ok (count-status controller :ok))
         (errors (count-status controller :error)))
    (cond ((controller-message controller))
          ((controller-stopping controller)
           (format nil "Stopping: finishing the files in hand (~d of ~d converted)…"
                   (+ ok errors) total))
          ((controller-running controller)
           (format nil "Converted ~d of ~d…" (+ ok errors) total))
          ((plusp (+ ok errors))
           (format nil "~d converted, ~d failed~@[ — double-click a file to see why~]."
                   ok errors (plusp errors)))
          ((zerop (length (input-path controller)))
           "Choose a folder of images to convert.")
          ((not (directory-exists-p (input-path controller)))
           "The input folder does not exist.")
          ((zerop total)
           (format nil "No images in this folder~:[~; or its subfolders~]." (recursive-p controller)))
          ((same-folder-p controller)
           (format nil "~d image~:p to convert, beside the originals: the output folder is the input folder.~a"
                   total (skipped-text controller)))
          (t
           (format nil "~d image~:p to convert.~a" total (skipped-text controller))))))

(defun skipped-text (controller)
  (let ((skipped (controller-skipped controller)))
    (if (plusp skipped)
        (format nil " ~d converted by an earlier run ~:*~[~;is~:;are~] not listed." skipped)
        "")))

(defun refresh-controls (controller)
  "Make the controls agree with the state: the status line, the button's
title, and which options can be changed."
  (let ((running (controller-running controller)))
    (objc:invoke (controller-status-label controller) "setStringValue:" (status-line controller))
    (objc:invoke (controller-convert-button controller) "setTitle:"
                 (cond ((controller-stopping controller) "Stopping…")
                       (running "Stop")
                       (t "Convert")))
    (objc:invoke (controller-convert-button controller) "setEnabled:"
                 (and (not (controller-stopping controller))
                      (or running (plusp (length (controller-entries controller))))))
    (dolist (control (controller-option-controls controller))
      (objc:invoke control "setEnabled:" (not running)))
    (enable-setting-controls controller)))

(defun output-excluded (input output)
  "OUTPUT, when it is a folder inside INPUT and so must be left out of the
scan.  Both are canonical paths.  The same folder is not excluded: that would
leave nothing to convert."
  (and (plusp (length output))
       (string/= output input)
       (inside-directory-p output input)
       output))

(defun same-folder-p (controller)
  "Whether the output folder is the input folder, however each was written."
  (let ((input (input-path controller))
        (output (output-path controller)))
    (and (plusp (length input)) (plusp (length output))
         (string= (canonical-path input) (canonical-path output)))))

(defun rescan (controller)
  "Find the images in the input folder again, and plan where each is to go.
Any statuses from a conversion are cleared: they were for other options."
  (let* ((input (canonical-path (input-path controller)))
         (output (let ((output (output-path controller)))
                   (if (plusp (length output)) (canonical-path output) "")))
         (format (selected-format controller))
         (found (and (directory-exists-p input)
                     (scan-directory input :recursive (recursive-p controller)
                                           :exclude (output-excluded input output)))))
    ;; What an earlier run wrote beside the originals is not converted again.
    (multiple-value-bind (paths skipped) (without-earlier-conversions found)
      (let ((entries (mapcar (lambda (path)
                               (make-entry :input path :relative (relative-name path input)))
                             paths)))
        (when (and format (plusp (length output)))
          (plan-batch entries output format))
        (setf (controller-entries controller) (coerce entries 'vector)
              (controller-skipped controller) skipped
              (controller-message controller) nil)))
    (objc:invoke (controller-table controller) "reloadData")
    (refresh-controls controller)
    controller))

(defun options-changed (controller)
  ;; The format may be another one, with settings of its own.
  (show-format-settings controller)
  (rescan controller)
  (save-settings controller))

;;; The options -----------------------------------------------------------------------

(defun choose-directory (&key prompt message start create)
  "Ask for one folder with an open panel.  Answers its path, or NIL."
  (let ((panel (objc:invoke "NSOpenPanel" "openPanel")))
    (objc:invoke panel "setCanChooseDirectories:" t)
    (objc:invoke panel "setCanChooseFiles:" nil)
    (objc:invoke panel "setAllowsMultipleSelection:" nil)
    (objc:invoke panel "setCanCreateDirectories:" (and create t))
    (objc:invoke panel "setPrompt:" prompt)
    (objc:invoke panel "setMessage:" message)
    (when (directory-exists-p (or start ""))
      (objc:invoke panel "setDirectoryURL:" (objc:invoke "NSURL" "fileURLWithPath:" start)))
    (when (= +ns-modal-response-ok+ (objc:invoke panel "runModal"))
      (let ((urls (objc:invoke panel "URLs")))
        (and (plusp (objc:invoke urls "count"))
             (objc:invoke-into 'string (objc:invoke urls "objectAtIndex:" 0) "path"))))))

(defun set-input (controller path)
  "Make PATH the input folder.  With no output folder yet, one called
Converted inside it is suggested."
  (objc:invoke (controller-input-field controller) "setStringValue:" (abbreviate-path path))
  (when (zerop (length (output-path controller)))
    (objc:invoke (controller-output-field controller) "setStringValue:"
                 (abbreviate-path
                  (concatenate 'string (string-right-trim "/" path) "/Converted"))))
  (options-changed controller))

(defun set-output (controller path)
  (objc:invoke (controller-output-field controller) "setStringValue:" (abbreviate-path path))
  (options-changed controller))

(define-controller-method ("chooseInput:" :void) ((sender objc:objc-object-pointer))
  (unless (controller-running self)
    (let ((path (choose-directory :prompt "Choose" :start (input-path self)
                                  :message "Choose the folder of images to convert.")))
      (when path (set-input self path)))))

(define-controller-method ("chooseOutput:" :void) ((sender objc:objc-object-pointer))
  (unless (controller-running self)
    (let ((path (choose-directory :prompt "Choose" :create t
                                  :start (let ((output (output-path self)))
                                           (if (directory-exists-p output) output (input-path self)))
                                  :message "Choose the folder the converted images are written to.")))
      (when path (set-output self path)))))

(define-controller-method ("optionsChanged:" :void) ((sender objc:objc-object-pointer))
  (unless (controller-running self)
    (options-changed self)))

;;; The format's settings ---------------------------------------------------------------
;;;
;;; Compression, quality and lossless belong to a format: TIFF's LZW means
;;; nothing to JPEG.  So each format keeps its own, and choosing another
;;; format shows that one's.  They are remembered as Compression.<format>,
;;; Quality.<format> and Lossless.<format>, each a string.

(defun format-settings (controller name)
  "NAME's settings, as a plist: those chosen in this window, or remembered."
  (let ((table (controller-format-settings controller)))
    (multiple-value-bind (settings found) (gethash name table)
      (if found
          settings
          (setf (gethash name table)
                (let ((compression (default-string (format nil "Compression.~a" name)))
                      (quality (default-string (format nil "Quality.~a" name)))
                      (lossless (default-string (format nil "Lossless.~a" name))))
                  (list :compression (and compression (plusp (length compression)) compression)
                        :quality (and quality (ignore-errors (parse-integer quality)))
                        :lossless (equal lossless "1"))))))))

(defun set-format-settings (controller name &key compression quality lossless)
  "Make NAME's settings these, and remember them."
  (setf (gethash name (controller-format-settings controller))
        (list :compression compression :quality quality :lossless lossless))
  (when *remember-settings*
    (let ((defaults (user-defaults)))
      (objc:invoke defaults "setObject:forKey:" (or compression "")
                   (format nil "Compression.~a" name))
      (objc:invoke defaults "setObject:forKey:" (if quality (princ-to-string quality) "")
                   (format nil "Quality.~a" name))
      (objc:invoke defaults "setObject:forKey:" (if lossless "1" "0")
                   (format nil "Lossless.~a" name))))
  (when (let ((format (selected-format controller)))
          (and format (string-equal name (output-format-name format))))
    (show-format-settings controller)))

(defun selected-compression (controller)
  (let ((index (objc:invoke (controller-compression-popup controller) "indexOfSelectedItem")))
    (and (<= 0 index) (nth index (controller-compression-names controller)))))

(defun current-settings (controller)
  "The selected format's settings as CONVERT-FILE takes them: the quality only
where the format, with its compression, has one."
  (let ((format (selected-format controller)))
    (if (null format)
        '()
        (let* ((name (output-format-name format))
               (settings (format-settings controller name))
               (compression (getf settings :compression))
               (lossless (and (getf settings :lossless) (lossless-available-p name))))
          (multiple-value-bind (attribute default) (quality-attribute name compression)
            (list :compression compression
                  :quality (and attribute (not lossless) (or (getf settings :quality) default))
                  :lossless lossless))))))

(defun show-format-settings (controller)
  "Fill the settings row with the selected format's."
  (let ((popup (controller-compression-popup controller))
        (format (selected-format controller)))
    (objc:invoke popup "removeAllItems")
    (setf (controller-compression-names controller) '())
    (when format
      (let* ((name (output-format-name format))
             (choices (compression-choices name))
             (settings (format-settings controller name))
             (chosen (getf settings :compression)))
        (objc:invoke popup "addItemWithTitle:"
                     (if (= 1 (length choices)) (cdr (first choices)) "Default"))
        (setf (controller-compression-names controller) (list nil))
        (when (> (length choices) 1)
          (dolist (choice choices)
            (objc:invoke popup "addItemWithTitle:" (cdr choice))
            (setf (controller-compression-names controller)
                  (append (controller-compression-names controller) (list (car choice))))))
        (objc:invoke popup "selectItemAtIndex:"
                     (or (position chosen (controller-compression-names controller)
                                   :test #'equalp)
                         0))
        (multiple-value-bind (attribute default) (quality-attribute name chosen)
          (let ((quality (if attribute (or (getf settings :quality) default) 0)))
            (objc:invoke (controller-quality-slider controller) "setIntegerValue:" quality)
            (objc:invoke (controller-quality-label controller) "setStringValue:"
                         (if attribute (princ-to-string quality) ""))))
        (objc:invoke (controller-lossless-checkbox controller) "setState:"
                     (if (and (getf settings :lossless) (lossless-available-p name)) 1 0)))))
  (enable-setting-controls controller))

(defun enable-setting-controls (controller)
  "Each of the settings row's controls usable when the format has what it sets,
and nothing while converting."
  (let* ((running (controller-running controller))
         (format (selected-format controller))
         (name (and format (output-format-name format)))
         (settings (and name (format-settings controller name)))
         (lossless (and name (lossless-available-p name) (getf settings :lossless))))
    (when (controller-compression-popup controller)
      (objc:invoke (controller-compression-popup controller) "setEnabled:"
                   (and (not running) (> (length (controller-compression-names controller)) 1)))
      (let ((quality (and name (not lossless)
                          (quality-attribute name (getf settings :compression)) t)))
        (objc:invoke (controller-quality-slider controller) "setEnabled:"
                     (and (not running) quality))
        (objc:invoke (controller-quality-label controller) "setEnabled:"
                     (and (not running) quality)))
      (objc:invoke (controller-lossless-checkbox controller) "setEnabled:"
                   (and (not running) name (lossless-available-p name))))))

(defun settings-changed (controller)
  "Take the settings row into the selected format's settings."
  (let ((format (selected-format controller)))
    (when format
      (let* ((name (output-format-name format))
             (compression (selected-compression controller)))
        (set-format-settings
         controller name
         :compression compression
         :quality (and (quality-attribute name compression)
                       (objc:invoke (controller-quality-slider controller) "integerValue"))
         :lossless (= 1 (objc:invoke (controller-lossless-checkbox controller) "state")))))))

(define-controller-method ("settingsChanged:" :void) ((sender objc:objc-object-pointer))
  (unless (controller-running self)
    (settings-changed self)))

;;; Converting ------------------------------------------------------------------------

(defvar *quit-when-done* nil
  "Whether the application quits when a conversion finishes: the self test.")

(defparameter +progress-interval+ 0.1d0
  "Seconds between the main thread's looks at what the workers have done.")

(defun schedule-progress (controller)
  (objc:invoke (objc:objc-object-pointer controller)
               "performSelector:withObject:afterDelay:inModes:"
               (objc:coerce-to-selector "conversionProgress:")
               nil +progress-interval+ +run-loop-modes+))

(defun start-converting (controller)
  "Check the options, plan the batch afresh, and begin.  True if it began."
  (let ((input (input-path controller))
        (output (output-path controller))
        (format (selected-format controller)))
    (setf (controller-message controller)
          (cond ((not (directory-exists-p input)) "Choose an input folder that exists.")
                ((zerop (length output)) "Choose an output folder.")
                ((null format) "Choose an output format.")))
    (cond ((controller-message controller)
           (refresh-controls controller)
           nil)
          (t
           ;; The folder may have changed since it was listed.
           (rescan controller)
           (cond ((zerop (length (controller-entries controller)))
                  (refresh-controls controller)
                  nil)
                 (t
                  (save-settings controller)
                  (let ((settings (current-settings controller)))
                    (note "converting ~d file~:p from ~a to ~a as ~a, ~d at a time"
                          (length (controller-entries controller)) input output
                          (apply #'settings-text (output-format-name format) settings)
                          (min (length (controller-entries controller))
                               (or *worker-count* (processor-count))))
                    (setf (controller-run controller)
                          (start-batch (controller-entries controller) format
                                       :settings settings)
                          (controller-running controller) t
                          (controller-stopping controller) nil))
                  (refresh-controls controller)
                  (schedule-progress controller)
                  t))))))

(defun stop-converting (controller)
  "Hand out no more files.  The run ends when the ones in hand are done."
  (when (controller-run controller)
    (stop-batch (controller-run controller))
    (setf (controller-stopping controller) t)
    (note "stopping")
    (refresh-controls controller)))

(defun finish-converting (controller)
  (setf (controller-run controller) nil
        (controller-running controller) nil
        (controller-stopping controller) nil)
  (note "done: ~d ok, ~d failed"
        (count-status controller :ok) (count-status controller :error))
  (objc:invoke (controller-table controller) "reloadData")
  (refresh-controls controller)
  (when *quit-when-done*
    (objc:invoke (objc.runloop:shared-application) "terminate:" nil)))

(defun collect-progress (controller)
  "Log and show what the workers have finished since the last look, and end
the run when they all have.  Answers true while it goes on."
  (let ((run (controller-run controller)))
    (if (null run)
        nil
        ;; Whether they are done first: what they finished before is then
        ;; all in TAKE-FINISHED.
        (let* ((done (batch-done-p run))
               (finished (take-finished run))
               (entries (controller-entries controller)))
          (dolist (index finished)
            (let ((entry (aref entries index)))
              (note "~a: ~a~@[: ~a~]~@[ (~a)~]" (status-text (entry-status entry))
                    (entry-input entry) (entry-message entry) (entry-note entry))))
          (let ((table (controller-table controller)))
            ;; The rows being converted change too, not only the finished.
            (objc:invoke table "reloadData")
            (when finished
              (objc:invoke table "scrollRowToVisible:" (reduce #'max finished))))
          (cond (done
                 (finish-converting controller)
                 nil)
                (t
                 (refresh-controls controller)
                 t))))))

(define-controller-method ("conversionProgress:" :void) ((argument objc:objc-object-pointer))
  (when (collect-progress self)
    (schedule-progress self)))

(defun stop-and-wait (controller &key (timeout 30))
  "Stop converting, and wait for the files in hand: for quitting, so that none
is left half written."
  (let ((run (controller-run controller)))
    (when run
      (stop-batch run)
      (unless (wait-for-batch run :timeout timeout)
        (note "quit with files still being converted")))))

(define-controller-method ("convert:" :void) ((sender objc:objc-object-pointer))
  ;; So that a path still being typed is taken before it is read.
  (objc:invoke (controller-window self) "makeFirstResponder:" (cffi:null-pointer))
  (cond ((controller-stopping self))
        ((controller-running self) (stop-converting self))
        (t (start-converting self))))


;;; Details ---------------------------------------------------------------------------

(defun show-details (controller row)
  "An alert with what is known of ROW's conversion: where from, where to, and
the error or what was changed to fit the format."
  (let ((entries (controller-entries controller)))
    (when (< -1 row (length entries))
      (let ((entry (aref entries row))
            (alert (objc:invoke (objc:invoke "NSAlert" "alloc") "init")))
        (unwind-protect
             (multiple-value-bind (title text) (entry-details entry)
               (objc:invoke alert "setMessageText:" title)
               (objc:invoke alert "setInformativeText:" text)
               ;; NSAlertStyleCritical for a failure, else informational.
               (objc:invoke alert "setAlertStyle:" (if (eq :error (entry-status entry)) 2 1))
               (objc:invoke alert "addButtonWithTitle:" "OK")
               (let ((shown (if (and (eq :ok (entry-status entry))
                                     (probe-file (sb-ext:parse-native-namestring
                                                  (entry-output entry))))
                                (entry-output entry)
                                (entry-input entry))))
                 (objc:invoke alert "addButtonWithTitle:" "Show in Finder")
                 (when (= +ns-alert-second-button-return+ (objc:invoke alert "runModal"))
                   (objc:invoke (objc:invoke "NSWorkspace" "sharedWorkspace")
                                "selectFile:inFileViewerRootedAtPath:" shown ""))))
          (objc:release alert))))))

(define-controller-method ("showDetails:" :void) ((sender objc:objc-object-pointer))
  (show-details self (objc:invoke (controller-table self) "clickedRow")))

;;; The table's data ------------------------------------------------------------------

(defun column-key (column)
  (if (null-object-p column)
      ""
      (or (objc:invoke-into 'string column "identifier") "")))

(defun cell-text (controller key row)
  (let ((entries (controller-entries controller)))
    (if (< -1 row (length entries))
        (let ((entry (aref entries row)))
          (if (string= key "status")
              (status-text (entry-status entry))
              (entry-relative entry)))
        "")))

(define-controller-method ("numberOfRowsInTableView:" :long :on-error 0)
    ((table objc:objc-object-pointer))
  (length (controller-entries self)))

(define-controller-method ("tableView:objectValueForTableColumn:row:"
                           objc:objc-object-pointer
                           :on-error (cffi:null-pointer))
    ((table objc:objc-object-pointer)
     (column objc:objc-object-pointer)
     (row :long))
  ;; Autoreleased: an object a Lisp method answers is the caller's to release,
  ;; and a table releases nothing it is given here.
  (objc:string-to-ns-string (cell-text self (column-key column) row) t))

(defun emphasized-selection-p (table row)
  "Whether ROW is drawn in the accent colour: selected, in a table that has the
focus.  Without the focus a selection is pale grey, and wants ordinary text."
  (and (objc:invoke-bool table "isRowSelected:" row)
       (let ((window (objc:invoke table "window")))
         (and (not (null-object-p window))
              (objc:invoke-bool window "isKeyWindow")
              (cffi:pointer-eq (objc:invoke window "firstResponder") table)))))

;;; The status in colour: green for ok, red for error.  A row selected in the
;;; accent colour keeps the selection's own text colour, or red on blue would
;;; be unreadable.
(define-controller-method ("tableView:willDisplayCell:forTableColumn:row:" :void)
    ((table objc:objc-object-pointer)
     (cell objc:objc-object-pointer)
     (column objc:objc-object-pointer)
     (row :long))
  (let* ((entries (controller-entries self))
         (status (and (< -1 row (length entries)) (entry-status (aref entries row)))))
    (objc:invoke cell "setTextColor:"
                 (objc:invoke "NSColor"
                              (cond ((emphasized-selection-p table row)
                                     "alternateSelectedControlTextColor")
                                    ((not (string= "status" (column-key column))) "labelColor")
                                    ((eq status :ok) "systemGreenColor")
                                    ((eq status :error) "systemRedColor")
                                    ((eq status :converting) "secondaryLabelColor")
                                    (t "labelColor"))))))

;;; Resting the pointer on a row says what double-clicking it would.
(define-controller-method ("tableView:toolTipForCell:rect:tableColumn:row:mouseLocation:"
                           objc:objc-object-pointer
                           :on-error (cffi:null-pointer))
    ((table objc:objc-object-pointer)
     (cell objc:objc-object-pointer)
     (rect (:pointer :void))
     (column objc:objc-object-pointer)
     (row :long)
     (location cocoa:ns-point))
  (let ((entries (controller-entries self)))
    (if (< -1 row (length entries))
        (let ((entry (aref entries row)))
          (objc:string-to-ns-string
           (or (entry-message entry) (entry-note entry) (entry-input entry)) t))
        (cffi:null-pointer))))

;;; Building it -----------------------------------------------------------------------

(defun add-label (content text frame mask &key (alignment nil))
  (let ((label (objc:invoke "NSTextField" "labelWithString:" text)))
    (objc:invoke label "setFrame:" frame)
    (objc:invoke label "setAutoresizingMask:" mask)
    (when alignment
      ;; NSTextAlignmentRight is 2 on Apple silicon and Intel alike.
      (objc:invoke label "setAlignment:" alignment))
    (objc:invoke content "addSubview:" label)
    label))

(defun add-path-field (content frame mask target placeholder)
  "A text field for a folder's path, which tells TARGET when it is changed."
  (let ((field (objc:invoke (objc:invoke "NSTextField" "alloc") "initWithFrame:" frame)))
    (objc:invoke field "setAutoresizingMask:" mask)
    (objc:invoke field "setPlaceholderString:" placeholder)
    (objc:invoke (objc:invoke field "cell") "setLineBreakMode:" +ns-line-break-by-truncating-middle+)
    (objc:invoke (objc:invoke field "cell") "setSendsActionOnEndEditing:" t)
    (objc:invoke field "setTarget:" target)
    (objc:invoke field "setAction:" (objc:coerce-to-selector "optionsChanged:"))
    (objc:invoke content "addSubview:" field)
    (objc:release field)
    field))

(defun add-button (content title action frame mask target)
  (let ((button (objc:invoke "NSButton" "buttonWithTitle:target:action:"
                             title target (objc:coerce-to-selector action))))
    (objc:invoke button "setFrame:" frame)
    (objc:invoke button "setAutoresizingMask:" mask)
    (objc:invoke content "addSubview:" button)
    button))

(defun add-checkbox (content title frame mask target &optional (action "optionsChanged:"))
  (let ((checkbox (objc:invoke "NSButton" "checkboxWithTitle:target:action:"
                               title target (objc:coerce-to-selector action))))
    (objc:invoke checkbox "setFrame:" frame)
    (objc:invoke checkbox "setAutoresizingMask:" mask)
    (objc:invoke content "addSubview:" checkbox)
    checkbox))

(defun add-format-popup (content frame mask target formats)
  "A drop-down of FORMATS, by name and description."
  (let ((popup (objc:invoke (objc:invoke "NSPopUpButton" "alloc")
                            "initWithFrame:pullsDown:" frame nil)))
    (objc:invoke popup "setAutoresizingMask:" mask)
    (dolist (format formats)
      (objc:invoke popup "addItemWithTitle:" (output-format-title format)))
    (objc:invoke popup "setTarget:" target)
    (objc:invoke popup "setAction:" (objc:coerce-to-selector "optionsChanged:"))
    (objc:invoke content "addSubview:" popup)
    (objc:release popup)
    popup))

(defun add-column (table key title width &key (resizing 2))
  (let ((column (objc:invoke (objc:invoke "NSTableColumn" "alloc") "initWithIdentifier:" key)))
    (objc:invoke column "setTitle:" title)
    (objc:invoke column "setWidth:" width)
    (objc:invoke column "setResizingMask:" resizing)
    (objc:invoke column "setEditable:" nil)
    (objc:invoke (objc:invoke column "dataCell") "setLineBreakMode:"
                 +ns-line-break-by-truncating-middle+)
    (objc:invoke table "addTableColumn:" column)
    (objc:release column)
    column))

(defun add-table (content frame mask target)
  "The list of files in its scroll view.  Answers the table."
  (let ((scroll (objc:invoke (objc:invoke "NSScrollView" "alloc") "initWithFrame:" frame))
        ;; At the scroll view's own origin: FRAME's is a place in the window,
        ;; and a table given it draws its rows that far from its headers.
        (table (objc:invoke (objc:invoke "NSTableView" "alloc") "initWithFrame:"
                            (vector 0d0 0d0 (aref frame 2) (aref frame 3)))))
    (objc:invoke table "setStyle:" +ns-table-view-style-full-width+)
    ;; The file takes whatever width is going; the status keeps its own.
    (add-column table "file" "File" (- (aref frame 2) 110d0) :resizing 3)
    (add-column table "status" "Status" 80d0)
    (objc:invoke table "setUsesAlternatingRowBackgroundColors:" t)
    (objc:invoke table "setAllowsMultipleSelection:" nil)
    (objc:invoke table "setColumnAutoresizingStyle:" 1)
    (objc:invoke table "setDataSource:" target)
    (objc:invoke table "setDelegate:" target)
    (objc:invoke table "setTarget:" target)
    (objc:invoke table "setDoubleAction:" (objc:coerce-to-selector "showDetails:"))
    (objc:invoke scroll "setHasVerticalScroller:" t)
    (objc:invoke scroll "setAutohidesScrollers:" t)
    (objc:invoke scroll "setBorderType:" +ns-bezel-border+)
    (objc:invoke scroll "setAutoresizingMask:" mask)
    (objc:invoke scroll "setDocumentView:" table)
    (objc:invoke content "addSubview:" scroll)
    (objc:invoke table "sizeToFit")
    (objc:release table)
    (objc:release scroll)
    table))

(defparameter +window-width+ 680d0)
(defparameter +window-height+ 592d0)
(defparameter +options-height+ 168d0)

(defun add-options (controller content target)
  "The options pane, in a box across the top of the window: the two folders,
whether to look in subfolders, the format to write, and its settings."
  (let* ((box (objc:invoke (objc:invoke "NSBox" "alloc") "initWithFrame:"
                           (vector 14d0 (- +window-height+ +options-height+ 10d0)
                                   (- +window-width+ 28d0) +options-height+))))
    (objc:invoke box "setTitle:" "Options")
    (objc:invoke box "setAutoresizingMask:" (logior +flexible-width+ +flexible-bottom+))
    (objc:invoke content "addSubview:" box)
    (objc:release box)
    (let* ((inner (objc:invoke box "contentView"))
           (size (objc:invoke inner "frame"))
           (width (aref size 2))
           (height (aref size 3))
           (wide (logior +flexible-width+ +flexible-bottom+))
           (right (logior +flexible-left+ +flexible-bottom+))
           (left +flexible-bottom+)
           (field-x 112d0)
           (field-width (- width field-x 112d0))
           (controls '()))
      (flet ((folder-row (y label placeholder action)
               (add-label inner label (vector 8d0 (+ y 3d0) 100d0 17d0) left :alignment 2)
               (let ((field (add-path-field inner (vector field-x y field-width 22d0)
                                            wide target placeholder))
                     (button (add-button inner "Choose…" action
                                         (vector (- width 106d0) (- y 6d0) 100d0 32d0)
                                         right target)))
                 (push field controls)
                 (push button controls)
                 field)))
        (setf (controller-input-field controller)
              (folder-row (- height 34d0) "Input folder:" "The folder of images to convert"
                          "chooseInput:")
              (controller-output-field controller)
              (folder-row (- height 66d0) "Output folder:" "Where the converted images go"
                          "chooseOutput:"))
        (let ((y (- height 98d0)))
          (setf (controller-recursive-checkbox controller)
                (add-checkbox inner "Include subfolders" (vector field-x (+ y 2d0) 170d0 18d0)
                              left target))
          (push (controller-recursive-checkbox controller) controls)
          (add-label inner "Output format:" (vector 290d0 (+ y 3d0) 100d0 17d0) left :alignment 2)
          (setf (controller-format-popup controller)
                (add-format-popup inner (vector 394d0 (- y 2d0) (- width 394d0 6d0) 26d0)
                                  wide target (controller-formats controller)))
          (push (controller-format-popup controller) controls))
        ;; The format's settings.  Not among the option controls: which of
        ;; them can be used depends on the format (ENABLE-SETTING-CONTROLS).
        (let ((y (- height 130d0)))
          (add-label inner "Compression:" (vector 8d0 (+ y 3d0) 100d0 17d0) left :alignment 2)
          (setf (controller-compression-popup controller)
                (add-compression-popup inner (vector field-x (- y 2d0) 170d0 26d0) left target))
          (add-label inner "Quality:" (vector 290d0 (+ y 3d0) 100d0 17d0) left :alignment 2)
          (setf (controller-quality-slider controller)
                (add-slider inner (vector 394d0 y (- width 394d0 140d0) 22d0) wide target)
                (controller-quality-label controller)
                (add-label inner "" (vector (- width 140d0) (+ y 3d0) 34d0 17d0) right)
                (controller-lossless-checkbox controller)
                (add-checkbox inner "Lossless" (vector (- width 100d0) (+ y 2d0) 94d0 18d0)
                              right target "settingsChanged:"))))
      (setf (controller-option-controls controller) controls))))

(defun add-compression-popup (content frame mask target)
  "A drop-down of the format's compressions, filled by SHOW-FORMAT-SETTINGS."
  (let ((popup (objc:invoke (objc:invoke "NSPopUpButton" "alloc")
                            "initWithFrame:pullsDown:" frame nil)))
    (objc:invoke popup "setAutoresizingMask:" mask)
    (objc:invoke popup "setTarget:" target)
    (objc:invoke popup "setAction:" (objc:coerce-to-selector "settingsChanged:"))
    (objc:invoke content "addSubview:" popup)
    (objc:release popup)
    popup))

(defun add-slider (content frame mask target)
  "Quality, 0 to 100.  Continuous, so the number beside it follows the knob."
  (let ((slider (objc:invoke "NSSlider" "sliderWithValue:minValue:maxValue:target:action:"
                             75d0 0d0 100d0 target (objc:coerce-to-selector "settingsChanged:"))))
    (objc:invoke slider "setFrame:" frame)
    (objc:invoke slider "setAutoresizingMask:" mask)
    (objc:invoke slider "setContinuous:" t)
    (objc:invoke content "addSubview:" slider)
    slider))

(defun restore-settings (controller)
  "Put the remembered options into the controls."
  (let ((input (default-string "InputFolder"))
        (output (default-string "OutputFolder"))
        (format (default-string "OutputFormat")))
    (when input
      (objc:invoke (controller-input-field controller) "setStringValue:" (abbreviate-path input)))
    (when output
      (objc:invoke (controller-output-field controller) "setStringValue:" (abbreviate-path output)))
    (objc:invoke (controller-recursive-checkbox controller) "setState:"
                 (if (default-bool "IncludeSubfolders") 1 0))
    (unless (and format (select-format controller format))
      ;; PNG, when nothing is remembered: lossless and everywhere.
      (unless (select-format controller "PNG")
        (objc:invoke (controller-format-popup controller) "selectItemAtIndex:" 0)
        (show-format-settings controller)))))

(defun make-window-controller ()
  "A controller with its window built and not yet shown."
  (let* ((controller (make-instance 'window-controller))
         (target (objc:objc-object-pointer controller))
         (window (objc:invoke (objc:invoke "NSWindow" "alloc")
                              "initWithContentRect:styleMask:backing:defer:"
                              (vector 0d0 0d0 +window-width+ +window-height+)
                              +ns-window-style-mask+ +ns-backing-store-buffered+ t))
         (content (objc:invoke window "contentView")))
    (setf (controller-formats controller) (output-formats))
    ;; Or the close button frees a window this still points at.
    (objc:invoke window "setReleasedWhenClosed:" nil)
    (objc:invoke window "setTitle:" "Image Converter")
    (objc:invoke window "setContentMinSize:" #(560d0 400d0))
    ;; So that menu items with no target -- File > Convert -- reach it.
    (objc:invoke window "setDelegate:" target)
    (setf (controller-window controller) window)
    (add-options controller content target)
    ;; From the bottom up: the status line and the button, then the list.
    (setf (controller-status-label controller)
          (add-label content "" (vector 20d0 22d0 (- +window-width+ 160d0) 17d0)
                     (logior +flexible-width+ +flexible-top+))
          (controller-convert-button controller)
          (add-button content "Convert" "convert:"
                      (vector (- +window-width+ 124d0) 14d0 110d0 32d0)
                      (logior +flexible-left+ +flexible-top+) target))
    ;; Return converts, when no field is being typed in.
    (objc:invoke (controller-convert-button controller) "setKeyEquivalent:" (string #\Return))
    (let ((top (- +window-height+ +options-height+ 18d0)))
      (setf (controller-table controller)
            (add-table content (vector 20d0 56d0 (- +window-width+ 40d0) (- top 56d0))
                       (logior +flexible-width+ +flexible-height+) target)))
    (restore-settings controller)
    (objc:invoke window "center")
    (rescan controller)
    controller))

(defun show-window (controller)
  (objc:invoke (controller-window controller) "makeKeyAndOrderFront:" (cffi:null-pointer))
  (objc:invoke (objc.runloop:shared-application) "activateIgnoringOtherApps:" t)
  controller)
