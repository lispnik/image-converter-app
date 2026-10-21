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

;;; IM's libraries, in the bundle ----------------------------------------------------
;;;
;;; im reopens its libraries in an image restore hook, and asdf-macos-app adds
;;; Contents/Frameworks to CFFI's search path only later, in its toplevel.  So
;;; left alone, the application opens IM by bare name, dyld finds Homebrew's
;;; copy, and the process ends up with two of each library -- the bundle's and
;;; Homebrew's -- with the HEIF and AVIF drivers registered in the wrong libim,
;;; where IM's format list never sees them.  On a Mac without Homebrew it would
;;; find nothing at all.  This hook tells im where the bundle's copies are, and
;;; is put where it runs before im's own.

(defun bundled-library-directory ()
  "Contents/Frameworks, when running in a bundle that carries libim; else NIL."
  (let* ((runtime (ignore-errors (sb-ext:native-pathname sb-ext:*runtime-pathname*)))
         (frameworks (and runtime
                          (merge-pathnames "../Frameworks/"
                                           (uiop:pathname-directory-pathname runtime)))))
    (and frameworks
         (probe-file (merge-pathnames "libim.dylib" frameworks))
         (truename frameworks))))

(defun use-bundled-im-libraries ()
  (let ((directory (bundled-library-directory)))
    (when directory
      (setf im:*library-path* directory))))

;;; UIOP calls restore hooks in the order they were registered, which is the
;;; reverse of the list: last in the list is first to run.
(setf uiop:*image-restore-hook*
      (append (remove 'use-bundled-im-libraries uiop:*image-restore-hook*)
              (list 'use-bundled-im-libraries)))

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
