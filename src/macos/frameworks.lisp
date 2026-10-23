;;;; frameworks.lisp -- AppKit: loading it, its constants, and the log.
;;;;
;;;; Nothing foreign is made when this is loaded.  The application is a saved
;;;; image, and a pointer made in the build would be garbage in the run.

(in-package #:image-converter)

(defparameter +cocoa-framework+
  "/System/Library/Frameworks/Cocoa.framework/Versions/A/Cocoa")

(defun ensure-frameworks ()
  "Bring up the Objective-C runtime with AppKit in it.  Every entry point that
touches AppKit calls this first; in the bundle it is also what rebuilds the
classes defined here."
  (objc:ensure-objc-initialized :modules (list +cocoa-framework+)))

;;; Constants -------------------------------------------------------------------

(defconstant +ns-window-style-mask+ 15
  "Titled, closable, miniaturizable, resizable.")
(defconstant +ns-backing-store-buffered+ 2)

;;; Autoresizing: which of a view's margins and dimensions give when its
;;; superview changes size.  AppKit's y runs upwards, so "min y" is the bottom.
(defconstant +flexible-left+ 1)
(defconstant +flexible-width+ 2)
(defconstant +flexible-right+ 4)
(defconstant +flexible-bottom+ 8)
(defconstant +flexible-height+ 16)
(defconstant +flexible-top+ 32)

(defconstant +ns-modal-response-ok+ 1)
(defconstant +ns-bezel-border+ 2)
(defconstant +ns-table-view-style-full-width+ 1)
(defconstant +ns-alert-first-button-return+ 1000)
(defconstant +ns-alert-second-button-return+ 1001)
(defconstant +ns-line-break-by-truncating-middle+ 5)

(defparameter +run-loop-modes+
  #("NSDefaultRunLoopMode" "NSEventTrackingRunLoopMode" "NSModalPanelRunLoopMode")
  "The modes the next step of a conversion is queued for: the usual one, and
the ones that run while the window is resized or the details are up, so that
looking at one file's details does not stop the rest being converted.")

;;; Small things ------------------------------------------------------------------

(defun null-object-p (object)
  "Whether OBJECT is no Objective-C object at all."
  (or (null object) (cffi:null-pointer-p object)))

(defvar *log* nil
  "Where NOTE writes: the application's log, once MAIN has said so.")

(defun note (control &rest arguments)
  "Write a line to the log."
  (when *log*
    (ignore-errors
     (multiple-value-bind (second minute hour) (get-decoded-time)
       (format *log* "~&~2,'0d:~2,'0d:~2,'0d ~?~%" hour minute second control arguments))
     (finish-output *log*))))
