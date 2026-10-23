;;;; app.lisp -- the application: its delegate, its menu, and MAIN.

(in-package #:image-converter)

(defvar *controller* nil
  "The window's controller.  Held here because nothing in AppKit retains a
target, a data source or a delegate.")
(defvar *application-delegate* nil)

(objc:define-objc-class application-delegate ()
  ()
  (:objc-class-name "ImageConverterApplicationDelegate"))

;;; One window, and closing it is quitting.
(objc:define-objc-method ("applicationShouldTerminateAfterLastWindowClosed:"
                          objc:objc-bool)
    ((self application-delegate) (application objc:objc-object-pointer))
  (declare (ignorable self application))
  t)

(objc:define-objc-method ("applicationWillTerminate:" :void)
    ((self application-delegate) (notification objc:objc-object-pointer))
  (declare (ignorable self notification))
  (handler-case (when *controller*
                  (stop-and-wait *controller*)
                  (save-settings *controller*)
                  (note "quit"))
    (error (condition) (note "applicationWillTerminate: ~a" condition))))

;;; The menu ----------------------------------------------------------------------
;;;
;;; A program with no nib has no menu bar until it makes one, and without an
;;; Edit menu there is no Paste in the path fields.  Every target is nil: the
;;; responder chain finds the field for Paste, the window's delegate -- the
;;; controller -- for Convert, and the application for Quit.

(defun add-menu-item (menu title action key)
  (let ((item (objc:invoke (objc:invoke "NSMenuItem" "alloc")
                           "initWithTitle:action:keyEquivalent:"
                           title (objc:coerce-to-selector action) key)))
    (objc:invoke menu "addItem:" item)
    (objc:release item)
    item))

(defun add-submenu (main title items)
  "A top-level menu of ITEMS, each (TITLE ACTION [KEY]) or :SEPARATOR."
  (let ((menu (objc:invoke (objc:invoke "NSMenu" "alloc") "initWithTitle:" title))
        (holder (objc:invoke (objc:invoke "NSMenuItem" "alloc")
                             "initWithTitle:action:keyEquivalent:"
                             title (cffi:null-pointer) "")))
    (dolist (item items)
      (if (eq item :separator)
          (objc:invoke menu "addItem:" (objc:invoke "NSMenuItem" "separatorItem"))
          (destructuring-bind (item-title action &optional (key "")) item
            (add-menu-item menu item-title action key))))
    (objc:invoke holder "setSubmenu:" menu)
    (objc:invoke main "addItem:" holder)
    (objc:release holder)
    menu))

(defun install-menu ()
  (let ((main (objc:invoke (objc:invoke "NSMenu" "alloc") "initWithTitle:" "Main"))
        (application (objc.runloop:shared-application)))
    (add-submenu main "Image Converter"
                 '(("About Image Converter" "orderFrontStandardAboutPanel:")
                   :separator
                   ("Hide Image Converter" "hide:" "h")
                   ("Hide Others" "hideOtherApplications:" "H")
                   :separator
                   ("Quit Image Converter" "terminate:" "q")))
    (add-submenu main "File"
                 '(("Choose Input Folder…" "chooseInput:" "o")
                   ("Choose Output Folder…" "chooseOutput:" "O")
                   :separator
                   ("Convert" "convert:" "r")
                   :separator
                   ("Close" "performClose:" "w")))
    (add-submenu main "Edit"
                 '(("Undo" "undo:" "z")
                   ("Redo" "redo:" "Z")
                   :separator
                   ("Cut" "cut:" "x")
                   ("Copy" "copy:" "c")
                   ("Paste" "paste:" "v")
                   :separator
                   ("Select All" "selectAll:" "a")))
    (objc:invoke application "setWindowsMenu:"
                 (add-submenu main "Window"
                              '(("Minimize" "performMiniaturize:" "m")
                                ("Zoom" "performZoom:"))))
    (objc:invoke application "setMainMenu:" main)
    main))

;;; Starting ----------------------------------------------------------------------

(defun build-application ()
  "The controller, window, delegate and menu.  Answers the controller."
  (let ((controller (make-window-controller))
        (delegate (make-instance 'application-delegate)))
    (setf *controller* controller
          *application-delegate* delegate)
    (install-menu)
    (objc:invoke (objc.runloop:shared-application) "setDelegate:"
                 (objc:objc-object-pointer delegate))
    controller))

(defun self-test-folder ()
  "The folder IMAGE_CONVERTER_SELFTEST names, or NIL.

With it set, the application converts that folder as soon as the window is up
and quits when it is done; the log says how each file went.  It is how the
bundle is checked from a script, where nothing can click:

  open --env IMAGE_CONVERTER_SELFTEST=$PWD/samples -W \"build/Image Converter.app\"

The converted files go to a new temporary folder, which the log names, unless
IMAGE_CONVERTER_SELFTEST_OUTPUT names another; IMAGE_CONVERTER_SELFTEST_FORMAT
is the format, PNG if unset, and subfolders are included.
IMAGE_CONVERTER_SELFTEST_COMPRESSION, _QUALITY and _LOSSLESS (1) are the
format's settings, its defaults if unset.  Only these are used:
the options remembered from the last time the window was used are neither read
nor changed, because a test that converted whatever folder someone last chose
would write into it."
  (let ((value (uiop:getenv "IMAGE_CONVERTER_SELFTEST")))
    (and value (plusp (length value)) value)))

(defun start-self-test (controller input)
  (let ((output (or (let ((value (uiop:getenv "IMAGE_CONVERTER_SELFTEST_OUTPUT")))
                      (and value (plusp (length value)) value))
                    (sb-posix:mkdtemp
                     (concatenate 'string
                                  (string-right-trim "/" (or (uiop:getenv "TMPDIR") "/tmp"))
                                  "/image-converter-selftest-XXXXXX"))))
        (format (or (uiop:getenv "IMAGE_CONVERTER_SELFTEST_FORMAT") "PNG")))
    (setf *quit-when-done* t)
    (objc:invoke (controller-input-field controller) "setStringValue:" input)
    (objc:invoke (controller-output-field controller) "setStringValue:" output)
    (objc:invoke (controller-recursive-checkbox controller) "setState:" 1)
    (if (select-format controller format)
        (flet ((env (name)
                 (let ((value (uiop:getenv name)))
                   (and value (plusp (length value)) value))))
          (set-format-settings
           controller (output-format-name (selected-format controller))
           :compression (env "IMAGE_CONVERTER_SELFTEST_COMPRESSION")
           :quality (let ((quality (env "IMAGE_CONVERTER_SELFTEST_QUALITY")))
                      (and quality (parse-integer quality :junk-allowed t)))
           :lossless (equal (env "IMAGE_CONVERTER_SELFTEST_LOSSLESS") "1")))
        (note "self test: no format ~a" format))
    (rescan controller)
    (note "self test: ~a to ~a as ~a: ~a" input output format (status-line controller))
    (unless (start-converting controller)
      (note "self test: did not start: ~a" (status-line controller))
      (objc:invoke (objc.runloop:shared-application) "terminate:" nil))))

(defun main ()
  "The application's entry point.  Does not return."
  (setf *log* *error-output*)
  (handler-case
      (let ((self-test (self-test-folder))
            (controller nil))
        (when self-test
          (setf *remember-settings* nil))
        ;; How many files at once, when not one a processor: for measuring.
        (let ((workers (ignore-errors
                        (parse-integer (or (uiop:getenv "IMAGE_CONVERTER_WORKERS") "")))))
          (when (and workers (plusp workers))
            (setf *worker-count* workers)))
        (ensure-frameworks)
        (objc.runloop:shared-application)
        (note "IM formats: ~{~a~^ ~}" (mapcar #'output-format-name (output-formats)))
        (setf controller (build-application))
        (show-window controller)
        (note "ready")
        (when self-test
          (start-self-test controller self-test)))
    (error (condition)
      (note "could not start: ~a" condition)
      (sb-ext:exit :code 1 :abort t)))
  (objc.runloop:run-cocoa-application))
