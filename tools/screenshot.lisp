;;;; screenshot.lisp -- pictures of the window, drawn by the window itself.
;;;;
;;;;   make screenshot [INPUT=/some/folder/of/images] [FORMAT=GIF]
;;;;
;;;; Always draws doc/converting.png: the window part way through converting,
;;;; staged from a made-up list of files, so it needs no images and converts
;;;; nothing.  With INPUT, also builds the real window over INPUT, converts into
;;;; a scratch folder, and draws the window and the details of the first
;;;; failure (or the first file) into doc/window.png and doc/details.png.
;;;; Nothing is captured from the screen, so it needs no Screen Recording
;;;; permission and shows nothing else that is open.

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

;;; The window -----------------------------------------------------------------------

(defun open-window (input format)
  "A window controller showing INPUT, its Converted folder beside it, subfolders
included, and FORMAT, on screen."
  (objc.runloop:shared-application :activation-policy nil)
  ;; Light, whatever the Mac is set to, so that pictures taken on different
  ;; Macs match.
  (objc:invoke (objc.runloop:shared-application) "setAppearance:"
               (objc:invoke "NSAppearance" "appearanceNamed:" "NSAppearanceNameAqua"))
  (let ((controller (ic::make-window-controller)))
    (objc:invoke (ic::controller-window controller) "orderFront:" nil)
    (objc:invoke (ic::controller-input-field controller) "setStringValue:" input)
    (objc:invoke (ic::controller-output-field controller) "setStringValue:"
                 (format nil "~a/Converted" input))
    (objc:invoke (ic::controller-recursive-checkbox controller) "setState:" 1)
    (ic::select-format controller format)
    controller))

;;; Converting, staged -------------------------------------------------------------

(defparameter *staged-folder* "/Users/me/Pictures/Iceland 2026")

(defparameter *staged-files*
  '(("Reykjavik/harpa-at-dusk.jpg" :ok)
    ("Reykjavik/hallgrimskirkja.heic" :ok)
    ("Reykjavik/old-harbour.png" :ok)
    ("Golden Circle/geysir.dng" :ok)
    ("Golden Circle/gullfoss.tif" :ok)
    ("Golden Circle/thingvellir-rift.jpg" :ok)
    ("South Coast/seljalandsfoss.heic" :ok)
    ("South Coast/skogafoss.dng" :converting)
    ("South Coast/reynisfjara.jpg" :converting)
    ("South Coast/vik-church.tif" :converting)
    ("South Coast/plane-wreck.png" :converting)
    ("Glacier/jokulsarlon.heic" nil)
    ("Glacier/diamond-beach.jpg" nil)
    ("Glacier/ice-cave.dng" nil)
    ("Glacier/svinafellsjokull.jpg" nil)
    ("Snaefellsnes/kirkjufell.heic" nil)
    ("Snaefellsnes/budir-church.jpg" nil)
    ("northern-lights.exr" nil))
  "Relative names and statuses: some done, one converting per processor of a
small Mac, and the rest waiting.")

(defun draw-converting (&optional (path #p"doc/converting.png"))
  "The window part way through converting *STAGED-FILES* to WEBP.  The list is
set rather than scanned, and the window is told it is running, so the folder
need not exist and nothing is converted."
  (let ((controller (open-window *staged-folder* "WEBP")))
    (setf (ic::controller-entries controller)
          (coerce (loop for (relative status) in *staged-files*
                        collect (ic:make-entry
                                 :input (format nil "~a/~a" *staged-folder* relative)
                                 :relative relative
                                 :status status))
                  'vector)
          (ic::controller-skipped controller) 0
          (ic::controller-message controller) nil
          (ic::controller-running controller) t)
    (objc:invoke (ic::controller-table controller) "reloadData")
    (ic::refresh-controls controller)
    (write-png (frame-view (ic::controller-window controller)) path)
    (objc:invoke (ic::controller-window controller) "orderOut:" nil)))

;;; A real folder, converted -----------------------------------------------------

(defun draw-converted (input format)
  "The window after converting INPUT to FORMAT, with its first failure (or first
file) selected, and that file's details."
  (let* ((input (string-right-trim "/" input))
         (output (format nil "/tmp/image-converter-screenshot-~d" (get-universal-time)))
         (controller (open-window input format)))
    (ic::rescan controller)
    ;; Converted into scratch, not beside the images: the field says where the
    ;; user would put them, which is what the picture should show.
    (dolist (entry (coerce (ic::controller-entries controller) 'list))
      (setf (ic:entry-output entry)
            (concatenate 'string output "/"
                         (ic::relative-name (ic:entry-output entry)
                                            (format nil "~a/Converted" input)))))
    (ic:wait-for-batch (ic:start-batch (ic::controller-entries controller)
                                       (ic::selected-format controller)
                                       :settings (ic::current-settings controller)))
    (objc:invoke (ic::controller-table controller) "reloadData")
    (ic::refresh-controls controller)
    ;; Select the first failure, as a double-click on it would.
    (let* ((entries (ic::controller-entries controller))
           (row (or (position :error entries :key #'ic:entry-status) 0)))
      (objc:invoke (ic::controller-table controller)
                   "selectRowIndexes:byExtendingSelection:"
                   (objc:invoke "NSIndexSet" "indexSetWithIndex:" row) nil)
      (write-png (frame-view (ic::controller-window controller)) #p"doc/window.png")
      (when (plusp (length entries))
        (write-png (details-view (aref entries row)) #p"doc/details.png")))
    (uiop:delete-directory-tree (uiop:ensure-directory-pathname output)
                                :validate t :if-does-not-exist :ignore)))

(defun main ()
  (let ((input (uiop:getenv "INPUT"))
        (format (uiop:getenv "FORMAT"))
        (ic::*remember-settings* nil))
    (ic::ensure-frameworks)
    (objc:with-autorelease-pool ()
      (draw-converting)
      (when (plusp (length input))
        (draw-converted input (if (plusp (length format)) format "GIF"))))))
