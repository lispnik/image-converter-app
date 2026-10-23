;;;; ui-tests.lisp -- the real window, driven without a click.
;;;;
;;;; The window is built and never shown.  Its controls are set the way a click
;;;; or some typing would set them, the controller is told, and then the table
;;;; is asked what it shows.  Conversion runs on worker threads as in the
;;;; application, and the main thread's look at their progress, which the run
;;;; loop would make ten times a second, is made by hand: the run loop is not
;;;; running here.
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
        ;; No worker left writing into a folder about to be deleted.
        (ic::stop-and-wait controller)
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

(defun wait-for-conversion (controller)
  "Look at the workers' progress, as the run loop would, until they are done."
  (loop repeat 6000 while (ic::collect-progress controller) do (sleep 0.01)))

(defun run-to-completion (controller)
  "Press Convert and wait for the conversion to end."
  (objc:invoke (target controller) "convert:" (cffi:null-pointer))
  (wait-for-conversion controller))

(defun button-title (controller)
  (objc:invoke-into 'string (ic::controller-convert-button controller) "title"))

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

(test stop-finishes-the-files-in-hand-and-leaves-the-rest-blank
  (with-temporary-directory (dir)
    (dotimes (i 12) (make-sample (path dir "in" (format nil "~2,'0d.png" i)) :width 256 :height 256))
    (let ((ic:*worker-count* 2))
      (with-controller (controller)
        (set-options controller :input (path dir "in") :output (path dir "out") :format "BMP")
        (objc:invoke (target controller) "convert:" (cffi:null-pointer))
        ;; The button says Stop while it runs, and pressing it again stops.
        (is (string= "Stop" (button-title controller)))
        (objc:invoke (target controller) "convert:" (cffi:null-pointer))
        (is (string= "Stopping…" (button-title controller)))
        (is-false (enabled-p (ic::controller-convert-button controller)))
        (wait-for-conversion controller)
        (let ((statuses (column-cells controller "status")))
          ;; What was begun is finished, and nothing is left half done.
          (is (every (lambda (status) (member status '("ok" "") :test #'string=)) statuses)
              "~s" statuses)
          (is (member "" statuses :test #'string=) "nothing was left: ~s" statuses))
        (is (string= "Convert" (button-title controller)))
        (is-true (enabled-p (ic::controller-convert-button controller)))))))

(test several-files-at-once-each-as-alone
  (with-temporary-directory (dir)
    (dotimes (i 16)
      (make-sample (path dir "in" (format nil "~2,'0d.png" i))
                   :kind (nth (mod i 4) '(:rgb :rgba :map :gray))))
    (write-text (path dir "in" "zz-broken.png") "not an image")
    (let ((ic:*worker-count* 4))
      (with-controller (controller)
        (set-options controller :input (path dir "in") :output (path dir "out") :format "GIF")
        (run-to-completion controller)
        (is (equal (append (make-list 16 :initial-element "ok") '("error"))
                   (column-cells controller "status")))
        (is (search "16 converted, 1 failed" (status-line controller)))
        (dotimes (i 16)
          (let ((name (format nil "~2,'0d" i)))
            (is (< (mean-difference (gray-samples (path dir "in" (format nil "~a.png" name)))
                                    (gray-samples (path dir "out" (format nil "~a.gif" name))))
                   24))))))))

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

(test converting-in-place-twice-does-not-convert-the-first-runs-output
  (with-temporary-directory (dir)
    (make-sample (path dir "a.png"))
    (make-sample (path dir "sub" "b.png"))
    (with-controller (controller)
      (set-options controller :input dir :output dir :recursive t :format "JPEG")
      (is (equal '("a.png" "sub/b.png") (column-cells controller "file")))
      (run-to-completion controller)
      (is (equal '("ok" "ok") (column-cells controller "status")))
      ;; Looked at again, the folder has a.jpg and sub/b.jpg too, which this
      ;; run wrote: they are not listed, and the status line says so.
      (set-options controller)
      (is (equal '("a.png" "sub/b.png") (column-cells controller "file")))
      (is (search "2 converted by an earlier run are not listed" (status-line controller)))
      ;; Converting again replaces them rather than writing a-jpg.jpg.
      (run-to-completion controller)
      (is (equal '("ok" "ok") (column-cells controller "status")))
      (is (not (file-exists-p (path dir "a-jpg.jpg"))))
      (is (equal '("a.jpg" "a.png" "sub/b.jpg" "sub/b.png")
                 (names (ic:scan-directory dir :recursive t) dir))))))

(test the-same-format-in-place-twice
  (with-temporary-directory (dir)
    (make-sample (path dir "a.png"))
    (with-controller (controller)
      (set-options controller :input dir :output dir :format "PNG")
      (run-to-completion controller)
      (is (file-exists-p (path dir "a-png.png")))
      (set-options controller)
      (is (equal '("a.png") (column-cells controller "file")))
      (run-to-completion controller)
      (is (not (file-exists-p (path dir "a-png-png.png"))))
      (is (= 32 (load-back (path dir "a.png")))))))

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

;;; The format's settings ------------------------------------------------------------

(defun popup-titles (popup)
  (loop for index below (objc:invoke popup "numberOfItems")
        collect (objc:invoke-into 'string popup "itemTitleAtIndex:" index)))

(defun enabled-p (control)
  (objc:invoke-bool control "isEnabled"))

(test the-settings-row-follows-the-format
  (with-controller (controller)
    (let ((compression (ic::controller-compression-popup controller))
          (slider (ic::controller-quality-slider controller))
          (lossless (ic::controller-lossless-checkbox controller)))
      (set-options controller :format "PNG")
      ;; One compression: shown, and nothing to choose.
      (is (equal '("DEFLATE") (popup-titles compression)))
      (is-false (enabled-p compression))
      (is-false (enabled-p slider))
      (is-false (enabled-p lossless))
      (set-options controller :format "JPEG")
      (is-true (enabled-p slider))
      (is (= 75 (objc:invoke slider "integerValue")))
      (is-false (enabled-p lossless))
      (set-options controller :format "TIFF")
      (is (string= "Default" (first (popup-titles compression))))
      (is (member "LZW" (popup-titles compression) :test #'string=))
      (is-true (enabled-p compression))
      ;; Quality only once the compression is JPEG.
      (is-false (enabled-p slider))
      (ic::set-format-settings controller "TIFF" :compression "JPEG")
      (is-true (enabled-p slider))
      (set-options controller :format "HEIF")
      (is-true (enabled-p lossless))
      (is (= 80 (objc:invoke slider "integerValue"))))))

(test each-format-keeps-its-own-settings
  (with-controller (controller)
    (set-options controller :format "JPEG")
    (objc:invoke (ic::controller-quality-slider controller) "setIntegerValue:" 30)
    (objc:invoke (target controller) "settingsChanged:" (cffi:null-pointer))
    (set-options controller :format "TIFF")
    (let ((popup (ic::controller-compression-popup controller)))
      (objc:invoke popup "selectItemAtIndex:"
                   (position "NONE" (ic::controller-compression-names controller)
                             :test #'equal))
      (objc:invoke (target controller) "settingsChanged:" (cffi:null-pointer))
      (set-options controller :format "JPEG")
      (is (= 30 (objc:invoke (ic::controller-quality-slider controller) "integerValue")))
      (is (equal '(:compression nil :quality 30 :lossless nil)
                 (ic::current-settings controller)))
      (set-options controller :format "TIFF")
      (is (string= "NONE" (objc:invoke-into 'string popup "titleOfSelectedItem")))
      (is (equal '(:compression "NONE" :quality nil :lossless nil)
                 (ic::current-settings controller))))))

(test converting-uses-the-settings
  (with-temporary-directory (dir)
    (make-sample (path dir "in" "a.png") :width 256 :height 256)
    (with-controller (controller)
      (flet ((size-at (quality)
               (ic::set-format-settings controller "JPEG" :quality quality)
               (run-to-completion controller)
               (is (equal '("ok") (column-cells controller "status")))
               (file-size (path dir "out" "a.jpg"))))
        (set-options controller :input (path dir "in") :output (path dir "out") :format "JPEG")
        (is (< (size-at 10) (size-at 95)))
        (is (search "As: JPEG, quality 95"
                    (nth-value 1 (ic:entry-details
                                  (aref (ic::controller-entries controller) 0)))))))))

(test the-settings-cannot-be-changed-while-converting
  (with-temporary-directory (dir)
    (dotimes (i 2) (make-sample (path dir "in" (format nil "~d.png" i))))
    (with-controller (controller)
      (set-options controller :input (path dir "in") :output (path dir "out") :format "JPEG")
      (objc:invoke (target controller) "convert:" (cffi:null-pointer))
      (is-false (enabled-p (ic::controller-quality-slider controller)))
      (wait-for-conversion controller)
      (is-true (enabled-p (ic::controller-quality-slider controller))))))

(test choosing-a-format-in-code-shows-its-settings
  ;; As the screenshot tool and the self test choose it: not by the drop-down.
  (with-controller (controller)
    (ic::select-format controller "JPEG")
    (is-true (enabled-p (ic::controller-quality-slider controller)))
    (is (string= "75" (objc:invoke-into 'string (ic::controller-quality-label controller)
                                        "stringValue")))))
