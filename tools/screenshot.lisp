;;;; screenshot.lisp -- pictures of the window, drawn by the window itself.
;;;;
;;;;   make screenshot INPUT=/some/folder/of/images [FORMAT=GIF]
;;;;
;;;; Builds the real window over INPUT, converts into a scratch folder, and has
;;;; AppKit draw the window and the details of the first failure (or the first
;;;; file) into doc/.  Nothing is captured from the screen, so it needs no
;;;; Screen Recording permission and shows nothing else that is open.

(defpackage #:image-converter-screenshot
  (:use #:common-lisp)
  (:local-nicknames (#:ic #:image-converter))
  (:export #:main))

(in-package #:image-converter-screenshot)

(defun settle (&optional (seconds 0.3d0))
  "Let the run loop lay out and draw what is on screen."
  (objc:invoke (objc:invoke "NSRunLoop" "currentRunLoop") "runUntilDate:"
               (objc:invoke "NSDate" "dateWithTimeIntervalSinceNow:" seconds)))

(defun write-png (view path)
  "Draw VIEW, as it would be on screen, into a PNG at PATH.  Its window must
have been on screen, or nothing in it has drawn yet."
  (objc:invoke (objc:invoke view "window") "displayIfNeeded")
  (settle)
  (let* ((bounds (objc:invoke view "bounds"))
         (rep (objc:invoke view "bitmapImageRepForCachingDisplayInRect:" bounds)))
    (objc:invoke view "cacheDisplayInRect:toBitmapImageRep:" bounds rep)
    ;; NSBitmapImageFileTypePNG.
    (let ((data (objc:invoke rep "representationUsingType:properties:" 4
                             (objc:invoke "NSDictionary" "dictionary"))))
      (ensure-directories-exist path)
      (objc:invoke data "writeToFile:atomically:" (namestring path) t)
      (format t "~&wrote ~a~%" path))))

(defun frame-view (window)
  "The view that draws all of WINDOW: its title bar and background as well as
its content, which has no background of its own to draw."
  (objc:invoke (objc:invoke window "contentView") "superview"))

(defun details-view (entry)
  "The details alert for ENTRY, laid out but not run, and its content view."
  (let ((alert (objc:invoke (objc:invoke "NSAlert" "alloc") "init")))
    (multiple-value-bind (title text) (ic:entry-details entry)
      (objc:invoke alert "setMessageText:" title)
      (objc:invoke alert "setInformativeText:" text)
      (objc:invoke alert "setAlertStyle:" (if (eq :error (ic:entry-status entry)) 2 1))
      (objc:invoke alert "addButtonWithTitle:" "OK")
      (objc:invoke alert "addButtonWithTitle:" "Show in Finder")
      (objc:invoke alert "layout")
      (objc:invoke (objc:invoke alert "window") "orderFront:" nil)
      (values (frame-view (objc:invoke alert "window")) alert))))

(defun main ()
  (let ((input (uiop:getenv "INPUT"))
        (format (or (uiop:getenv "FORMAT") "GIF"))
        (output (format nil "/tmp/image-converter-screenshot-~d" (get-universal-time)))
        (ic::*remember-settings* nil))
    (unless (and input (plusp (length input)))
      (error "Set INPUT to a folder of images."))
    (ic::ensure-frameworks)
    (objc:with-autorelease-pool ()
      (objc.runloop:shared-application :activation-policy nil)
      ;; Light, whatever the Mac is set to, so that pictures taken on
      ;; different Macs match.
      (objc:invoke (objc.runloop:shared-application) "setAppearance:"
                   (objc:invoke "NSAppearance" "appearanceNamed:" "NSAppearanceNameAqua"))
      (let* ((controller (ic::make-window-controller))
             (window (ic::controller-window controller)))
        (objc:invoke window "orderFront:" nil)
        (objc:invoke (ic::controller-input-field controller) "setStringValue:"
                     (string-right-trim "/" input))
        (objc:invoke (ic::controller-output-field controller) "setStringValue:"
                     (format nil "~a/Converted" (string-right-trim "/" input)))
        (objc:invoke (ic::controller-recursive-checkbox controller) "setState:" 1)
        (ic::select-format controller format)
        (ic::rescan controller)
        ;; Converted into scratch, not beside the images: the field says where
        ;; the user would put them, which is what the picture should show.
        (dolist (entry (coerce (ic::controller-entries controller) 'list))
          (setf (ic:entry-output entry)
                (concatenate 'string output "/"
                             (ic::relative-name (ic:entry-output entry)
                                                (format nil "~a/Converted"
                                                        (string-right-trim "/" input))))))
        (setf (ic::controller-running controller) t
              (ic::controller-next controller) 0)
        (loop while (ic::convert-step controller))
        ;; Select the first failure, as a double-click on it would.
        (let* ((entries (ic::controller-entries controller))
               (row (or (position :error entries :key #'ic:entry-status) 0)))
          (objc:invoke (ic::controller-table controller)
                       "selectRowIndexes:byExtendingSelection:"
                       (objc:invoke "NSIndexSet" "indexSetWithIndex:" row) nil)
          (write-png (frame-view window) #p"doc/window.png")
          (when (plusp (length entries))
            (write-png (details-view (aref entries row)) #p"doc/details.png")))
        (uiop:delete-directory-tree (uiop:ensure-directory-pathname output)
                                    :validate t :if-does-not-exist :ignore)))))
