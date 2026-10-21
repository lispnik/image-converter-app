;;;; ui-tests.lisp -- the real window, driven without a click.
;;;;
;;;; The window is built and never shown.  Its controls are set the way a click
;;;; or some typing would set them, the controller is told, and then the table
;;;; is asked what it shows.  Conversion is stepped by hand rather than left to
;;;; the run loop, which is not running here.
;;;;
;;;; Skipped where there is no window server, which the count of skips says.

(in-package #:image-converter/tests)

(def-suite ui :in all-tests :description "The window.  Needs a window server.")
(in-suite ui)

(defun call-with-controller (function)
  (let ((controller nil)
        (ic::*remember-settings* nil))
    (unwind-protect
         (objc:with-autorelease-pool ()
           ;; No policy, so no Dock icon and no stolen focus.
           (objc.runloop:shared-application :activation-policy nil)
           (setf controller (ic::make-window-controller))
           (funcall function controller))
      (when controller
        (setf (ic::controller-running controller) nil)
        (objc:invoke (ic::controller-window controller) "close")))))

(defmacro with-controller ((controller) &body body)
  "Run BODY with CONTROLLER a new window controller, or skip."
  `(cond ((not (ignore-errors (ic::ensure-frameworks) t))
          (skip "Objective-C runtime not available"))
         ((not (objc.runloop:window-server-p))
          (skip "no window server"))
         (t (call-with-controller (lambda (,controller) ,@body)))))

(defun target (controller) (objc:objc-object-pointer controller))
(defun table (controller) (ic::controller-table controller))

(defun row-count (controller)
  (objc:invoke (target controller) "numberOfRowsInTableView:" (table controller)))

(defun cell (controller key row)
  "What the data source answers for the cell, as a string."
  (objc:invoke-into 'string (target controller)
                    "tableView:objectValueForTableColumn:row:"
                    (table controller)
                    (objc:invoke (table controller) "tableColumnWithIdentifier:" key)
                    row))

(defun column-cells (controller key)
  (loop for row below (row-count controller) collect (cell controller key row)))

(defun status-line (controller)
  (objc:invoke-into 'string (ic::controller-status-label controller) "stringValue"))

(defun set-field (field text)
  (objc:invoke field "setStringValue:" text))

(defun set-options (controller &key input output (recursive nil recursive-p) format)
  (when input (set-field (ic::controller-input-field controller) input))
  (when output (set-field (ic::controller-output-field controller) output))
  (when recursive-p
    (objc:invoke (ic::controller-recursive-checkbox controller) "setState:" (if recursive 1 0)))
  (when format (ic::select-format controller format))
  ;; As the controls would on a change.
  (objc:invoke (target controller) "optionsChanged:" (cffi:null-pointer)))

(defun run-to-completion (controller)
  "Press Convert and step the conversion until it stops."
  (objc:invoke (target controller) "convert:" (cffi:null-pointer))
  (loop repeat 1000 while (ic::convert-step controller)))

(test the-drop-down-lists-every-format
  (with-controller (controller)
    (let ((popup (ic::controller-format-popup controller)))
      (is (= (length (ic:output-formats)) (objc:invoke popup "numberOfItems")))
      (loop for format in (ic:output-formats)
            for index from 0
            do (is (string= (ic:output-format-title format)
                            (objc:invoke-into 'string popup "itemTitleAtIndex:" index)))))))

(test png-is-chosen-when-nothing-is-remembered
  (with-controller (controller)
    (is (string= "PNG" (ic:output-format-name (ic::selected-format controller))))))

(test the-table-lists-the-input-folder
  (with-temporary-directory (dir)
    (make-sample (path dir "in" "b.png"))
    (make-sample (path dir "in" "a.jpg") :format "JPEG")
    (make-sample (path dir "in" "sub" "c.png"))
    (write-text (path dir "in" "readme.txt") "")
    (with-controller (controller)
      (set-options controller :input (path dir "in") :output (path dir "out"))
      (is (equal '("a.jpg" "b.png") (column-cells controller "file")))
      (is (equal '("" "") (column-cells controller "status")))
      (is (search "2 images" (status-line controller)))
      (set-options controller :recursive t)
      (is (equal '("a.jpg" "b.png" "sub/c.png") (column-cells controller "file")))
      (set-options controller :recursive nil)
      (is (= 2 (row-count controller))))))

(test choosing-an-input-suggests-an-output
  (with-temporary-directory (dir)
    (make-sample (path dir "in" "a.png"))
    (with-controller (controller)
      (ic::set-input controller (path dir "in"))
      (is (string= (path dir "in" "Converted") (ic::output-path controller)))
      ;; And an output already chosen is left alone.
      (ic::set-output controller (path dir "elsewhere"))
      (ic::set-input controller (path dir "in"))
      (is (string= (path dir "elsewhere") (ic::output-path controller))))))

(test converting-fills-in-the-status-column
  (with-temporary-directory (dir)
    (make-sample (path dir "in" "good.png"))
    (write-text (path dir "in" "bad.png") "not an image")
    (make-sample (path dir "in" "sub" "deep.png") :kind :map)
    (with-controller (controller)
      (set-options controller :input (path dir "in") :output (path dir "out")
                              :recursive t :format "JPEG")
      (is (equal '("bad.png" "good.png" "sub/deep.png") (column-cells controller "file")))
      (run-to-completion controller)
      (is (not (ic::controller-running controller)))
      (is (equal '("error" "ok" "ok") (column-cells controller "status")))
      (is (file-exists-p (path dir "out" "good.jpg")))
      (is (file-exists-p (path dir "out" "sub" "deep.jpg")))
      (is (search "2 converted, 1 failed" (status-line controller)))
      ;; The details of the failure are what double-clicking it shows.
      (is (search "could not be converted"
                  (ic:entry-details (aref (ic::controller-entries controller) 0)))))))

(test the-output-inside-the-input-is-not-listed-after-converting
  (with-temporary-directory (dir)
    (make-sample (path dir "in" "a.png"))
    (with-controller (controller)
      (set-options controller :input (path dir "in") :output (path dir "in" "Converted")
                              :recursive t :format "BMP")
      (run-to-completion controller)
      (is (file-exists-p (path dir "in" "Converted" "a.bmp")))
      (set-options controller)
      (is (equal '("a.png") (column-cells controller "file"))))))

(test stop-leaves-the-rest-blank
  (with-temporary-directory (dir)
    (dotimes (i 3) (make-sample (path dir "in" (format nil "~d.png" i))))
    (with-controller (controller)
      (set-options controller :input (path dir "in") :output (path dir "out") :format "BMP")
      (objc:invoke (target controller) "convert:" (cffi:null-pointer))
      (ic::convert-step controller)
      ;; Stop: the button says Stop while it runs, and pressing it again stops.
      (is (string= "Stop" (objc:invoke-into 'string (ic::controller-convert-button controller)
                                            "title")))
      (objc:invoke (target controller) "convert:" (cffi:null-pointer))
      (is (null (ic::convert-step controller)))
      (is (equal '("ok" "" "") (column-cells controller "status")))
      (is (string= "Convert" (objc:invoke-into 'string (ic::controller-convert-button controller)
                                               "title"))))))

(test convert-says-what-is-missing
  (with-controller (controller)
    (set-options controller :input "/no/such/folder")
    (is (search "does not exist" (status-line controller)))
    (objc:invoke (target controller) "convert:" (cffi:null-pointer))
    (is (not (ic::controller-running controller)))
    (is (search "input folder" (status-line controller)))))

(test changing-the-format-clears-the-statuses
  (with-temporary-directory (dir)
    (make-sample (path dir "in" "a.png"))
    (with-controller (controller)
      (set-options controller :input (path dir "in") :output (path dir "out") :format "BMP")
      (run-to-completion controller)
      (is (equal '("ok") (column-cells controller "status")))
      (set-options controller :format "TIFF")
      (is (equal '("") (column-cells controller "status")))
      (is (string= (path (ic::canonical-path dir) "out" "a.tif")
                   (ic:entry-output (aref (ic::controller-entries controller) 0)))))))

;;; The session this was found in: input /private/tmp/x, output /tmp/x, which
;;; is the same folder.  Each run wrote beside the originals and, taking the
;;; output for somewhere else, listed the previous run's files as new inputs.

(test the-same-folder-through-a-link-is-the-same-folder
  (with-temporary-directory (dir)
    (make-sample (path dir "a.png"))
    (make-sample (path dir "b.pcx") :format "PCX")
    (with-controller (controller)
      (set-options controller :input (ic::canonical-path dir) :output dir :format "BMP")
      (is (search "beside the originals" (status-line controller)))
      (run-to-completion controller)
      (is (equal '("ok" "ok") (column-cells controller "status")))
      ;; Nothing written over, and the originals still images.
      (is (= 32 (load-back (path dir "a.png"))))
      (is (= 32 (load-back (path dir "b.pcx")))))))

(test an-output-inside-the-input-through-a-link-is-left-out
  (with-temporary-directory (dir)
    (make-sample (path dir "a.png"))
    (with-controller (controller)
      (set-options controller :input (ic::canonical-path dir) :output (path dir "Converted")
                              :recursive t :format "BMP")
      (run-to-completion controller)
      (is (file-exists-p (path dir "Converted" "a.bmp")))
      (set-options controller)
      (is (equal '("a.png") (column-cells controller "file"))))))

(test a-tilde-is-the-home-folder
  (is (string= (concatenate 'string (string-right-trim "/" (namestring (user-homedir-pathname)))
                            "/Pictures")
               (ic::expand-path " ~/Pictures/ ")))
  (is (string= "/" (ic::expand-path "/")))
  (is (string= "~user/x" (ic::expand-path "~user/x")))
  (let ((home (string-right-trim "/" (namestring (user-homedir-pathname)))))
    (is (string= "~/Pictures" (ic::abbreviate-path (concatenate 'string home "/Pictures"))))
    (is (string= "~" (ic::abbreviate-path home)))
    (is (string= (concatenate 'string home "x/y") (ic::abbreviate-path (concatenate 'string home "x/y"))))
    (is (string= "/tmp/a" (ic::abbreviate-path "/tmp/a")))))
