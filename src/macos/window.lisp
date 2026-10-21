;;;; window.lisp -- the window: the options, the list of files, Convert.
;;;;
;;;; One controller is the target of every control and the table's data source
;;;; and delegate.  What the table shows is a vector of ENTRYs (batch.lisp); a
;;;; change to any option scans the input folder again and plans where each
;;;; file is to go.
;;;;
;;;; Converting runs on the main thread, one file each pass of the run loop:
;;;; each step converts a file, redraws, and queues the next.  So the window
;;;; keeps answering between files, Stop is honoured at the next one, and no
;;;; thread other than the main one ever touches AppKit or IM.

(in-package #:image-converter)

(objc:define-objc-class window-controller ()
  ((window :initform nil :accessor controller-window)
   (input-field :initform nil :accessor controller-input-field)
   (output-field :initform nil :accessor controller-output-field)
   (recursive-checkbox :initform nil :accessor controller-recursive-checkbox)
   (format-popup :initform nil :accessor controller-format-popup)
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
   (next :initform 0 :accessor controller-next
         :documentation "The row converted next, while running.")
   (message :initform nil :accessor controller-message
            :documentation "Something to say in place of the count of files."))
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
          ((controller-running controller)
           (format nil "Converting ~d of ~d…" (min total (1+ (controller-next controller))) total))
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
           (format nil "~d image~:p to convert, beside the originals: the output folder is the input folder."
                   total))
          (t
           (format nil "~d image~:p to convert." total)))))

(defun refresh-controls (controller)
  "Make the controls agree with the state: the status line, the button's
title, and which options can be changed."
  (let ((running (controller-running controller)))
    (objc:invoke (controller-status-label controller) "setStringValue:" (status-line controller))
    (objc:invoke (controller-convert-button controller) "setTitle:" (if running "Stop" "Convert"))
    (objc:invoke (controller-convert-button controller) "setEnabled:"
                 (or running (plusp (length (controller-entries controller)))))
    (dolist (control (controller-option-controls controller))
      (objc:invoke control "setEnabled:" (not running)))))

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
         (paths (and (directory-exists-p input)
                     (scan-directory input :recursive (recursive-p controller)
                                           :exclude (output-excluded input output))))
         (entries (mapcar (lambda (path)
                            (make-entry :input path :relative (relative-name path input)))
                          paths)))
    (when (and format (plusp (length output)))
      (plan-batch entries output format))
    (setf (controller-entries controller) (coerce entries 'vector)
          (controller-message controller) nil)
    (objc:invoke (controller-table controller) "reloadData")
    (refresh-controls controller)
    controller))

(defun options-changed (controller)
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

;;; Converting ------------------------------------------------------------------------

(defvar *quit-when-done* nil
  "Whether the application quits when a conversion finishes: the self test.")

(defun schedule-step (controller)
  (objc:invoke (objc:objc-object-pointer controller)
               "performSelector:withObject:afterDelay:inModes:"
               (objc:coerce-to-selector "convertStep:")
               nil 0d0 +run-loop-modes+))

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
                  (note "converting ~d file~:p from ~a to ~a as ~a"
                        (length (controller-entries controller)) input output
                        (output-format-name format))
                  (setf (controller-running controller) t
                        (controller-next controller) 0)
                  (refresh-controls controller)
                  (schedule-step controller)
                  t))))))

(defun stop-converting (controller)
  (setf (controller-running controller) nil)
  (refresh-controls controller))

(defun convert-step (controller)
  "Convert the next file, or finish.  Answers true while there is more to do."
  (let ((entries (controller-entries controller))
        (index (controller-next controller))
        (format (selected-format controller)))
    (cond ((not (controller-running controller)) nil)
          ((or (>= index (length entries)) (null format))
           (setf (controller-running controller) nil)
           (note "done: ~d ok, ~d failed"
                 (count-status controller :ok) (count-status controller :error))
           (refresh-controls controller)
           (when *quit-when-done*
             (objc:invoke (objc.runloop:shared-application) "terminate:" nil))
           nil)
          (t
           (let ((entry (aref entries index)))
             (convert-entry entry format)
             (note "~a: ~a~@[: ~a~]~@[ (~a)~]" (status-text (entry-status entry))
                   (entry-input entry) (entry-message entry) (entry-note entry)))
           (incf (controller-next controller))
           (let ((table (controller-table controller)))
             (objc:invoke table "reloadData")
             (objc:invoke table "scrollRowToVisible:" index))
           (refresh-controls controller)
           t))))

(define-controller-method ("convert:" :void) ((sender objc:objc-object-pointer))
  ;; So that a path still being typed is taken before it is read.
  (objc:invoke (controller-window self) "makeFirstResponder:" (cffi:null-pointer))
  (if (controller-running self)
      (stop-converting self)
      (start-converting self)))

(define-controller-method ("convertStep:" :void) ((argument objc:objc-object-pointer))
  (when (convert-step self)
    (schedule-step self)))

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

(defun add-checkbox (content title frame mask target)
  (let ((checkbox (objc:invoke "NSButton" "checkboxWithTitle:target:action:"
                               title target (objc:coerce-to-selector "optionsChanged:"))))
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
(defparameter +window-height+ 560d0)
(defparameter +options-height+ 136d0)

(defun add-options (controller content target)
  "The options pane, in a box across the top of the window: the two folders,
whether to look in subfolders, and the format to write."
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
          (push (controller-format-popup controller) controls)))
      (setf (controller-option-controls controller) controls))))

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
      (or (select-format controller "PNG")
          (objc:invoke (controller-format-popup controller) "selectItemAtIndex:" 0)))))

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
