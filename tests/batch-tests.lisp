;;;; batch-tests.lisp -- where each file goes, and the status it is left with.

(in-package #:image-converter/tests)

(def-suite batch :in all-tests :description "Planning and recording a batch.")
(in-suite batch)

(defun entries-for (directory &rest relatives)
  (mapcar (lambda (relative)
            (ic:make-entry :input (path directory relative) :relative relative))
          relatives))

(test outputs-mirror-the-subfolders
  (let ((entries (ic:plan-batch (entries-for "/in" "a.png" "sub/b.jpg" "sub/deeper/c.gif")
                                "/out" (format-named "TIFF"))))
    (is (equal '("/out/a.tif" "/out/sub/b.tif" "/out/sub/deeper/c.tif")
               (mapcar #'ic:entry-output entries)))))

(test a-trailing-slash-on-the-output-makes-no-difference
  (let ((entries (ic:plan-batch (entries-for "/in" "a.png") "/out/" (format-named "TIFF"))))
    (is (string= "/out/a.tif" (ic:entry-output (first entries))))))

(test two-inputs-that-would-collide-keep-their-extensions
  (let ((entries (ic:plan-batch (entries-for "/in" "photo.png" "photo.JPG" "other.png")
                                "/out" (format-named "TIFF"))))
    (is (equal '("/out/photo-png.tif" "/out/photo-jpg.tif" "/out/other.tif")
               (mapcar #'ic:entry-output entries)))))

(test an-input-is-never-the-output
  ;; In its own folder, to its own format.
  (let ((entries (ic:plan-batch (entries-for "/in" "a.png" "b.jpg") "/in" (format-named "PNG"))))
    (is (equal '("/in/a-png.png" "/in/b.png") (mapcar #'ic:entry-output entries))))
  ;; Nor another input beside it: b.jpg to PNG must not land on b.png.
  (let ((entries (ic:plan-batch (entries-for "/in" "b.jpg" "b.png") "/in" (format-named "PNG"))))
    (is (notany (lambda (output) (member output '("/in/b.jpg" "/in/b.png") :test #'string-equal))
                (mapcar #'ic:entry-output entries)))))

(test a-name-with-no-extension-or-a-dotted-folder
  (let ((entries (ic:plan-batch (entries-for "/in" "v1.2/photo.png" "v1.2/photo")
                                "/out" (format-named "BMP"))))
    (is (equal '("/out/v1.2/photo-png.bmp" "/out/v1.2/photo.bmp")
               (mapcar #'ic:entry-output entries)))))

(test planning-clears-an-earlier-run
  (let ((entry (ic:make-entry :input "/in/a.png" :relative "a.png"
                              :status :error :message "old" :note "old")))
    (ic:plan-batch (list entry) "/out" (format-named "PNG"))
    (is (null (ic:entry-status entry)))
    (is (null (ic:entry-message entry)))
    (is (null (ic:entry-note entry)))))

(test status-text-is-blank-ok-or-error
  (is (string= "" (ic:status-text nil)))
  (is (string= "ok" (ic:status-text :ok)))
  (is (string= "error" (ic:status-text :error))))

(test converting-records-ok-and-error-and-never-signals
  (with-temporary-directory (dir)
    (make-sample (path dir "in" "good.png"))
    (write-text (path dir "in" "bad.png") "not an image")
    (let ((entries (ic:plan-batch (entries-for (path dir "in") "bad.png" "good.png")
                                  (path dir "out") (format-named "JPEG"))))
      (dolist (entry entries)
        (finishes (ic:convert-entry entry (format-named "JPEG"))))
      (destructuring-bind (bad good) entries
        (is (eq :error (ic:entry-status bad)))
        (is (plusp (length (ic:entry-message bad))))
        (is (eq :ok (ic:entry-status good)))
        (is (null (ic:entry-message good)))
        (is (file-exists-p (path dir "out" "good.jpg")))
        (is (not (file-exists-p (path dir "out" "bad.jpg"))))))))

(test im-s-trailing-path-is-left-off-the-message
  (is (string= "Invalid or unrecognized file format."
               (ic::without-paths "Invalid or unrecognized file format: /in/a.png." "/in/a.png" "/out/a.tif")))
  (is (string= "Error writing file."
               (ic::without-paths "Error writing file: /out/a.tif." "/in/a.png" "/out/a.tif")))
  (is (string= "Something else: /x." (ic::without-paths "Something else: /x." "/in/a.png" nil))))

(test an-unplanned-entry-is-an-error-not-a-crash
  (let ((entry (ic:make-entry :input "/in/a.png" :relative "a.png")))
    (ic:convert-entry entry (format-named "PNG"))
    (is (eq :error (ic:entry-status entry)))))

(test writing-over-the-input-is-refused
  (with-temporary-directory (dir)
    (let ((entry (ic:make-entry :input (make-sample (path dir "a.png")) :relative "a.png"
                                :output (path dir "a.png"))))
      (ic:convert-entry entry (format-named "PNG"))
      (is (eq :error (ic:entry-status entry)))
      (is (search "replace the original" (ic:entry-message entry))))))

(test details-say-what-happened
  (let ((entry (ic:make-entry :input "/in/a.png" :relative "a.png" :output "/out/a.jpg"
                              :status :error :message "It went wrong.")))
    (multiple-value-bind (title text) (ic:entry-details entry)
      (is (search "could not be converted" title))
      (is (search "It went wrong." text))
      (is (search "/in/a.png" text))
      (is (search "/out/a.jpg" text))))
  (let ((entry (ic:make-entry :input "/in/a.png" :relative "a.png" :output "/out/a.gif"
                              :status :ok :note "Converted to palette.")))
    (multiple-value-bind (title text) (ic:entry-details entry)
      (is (search "was converted" title))
      (is (search "Converted to palette." text))))
  (is (search "not been converted"
              (ic:entry-details (ic:make-entry :input "/in/a.png" :relative "a.png")))))

(test an-input-is-never-the-output-through-a-link
  ;; The inputs as the scan gives them, canonical; the output folder as typed,
  ;; through /tmp.  The very case that wrote among a user's originals.
  (with-temporary-directory (dir)
    (let* ((real (ic::canonical-path dir))
           (entries (ic:plan-batch (entries-for real "a.png" "b.jpg" "b.png") dir
                                   (format-named "PNG"))))
      (is (notany (lambda (output)
                    (member output (mapcar #'ic:entry-input entries) :test #'string-equal))
                  (mapcar #'ic:entry-output entries))
          "~s" (mapcar #'ic:entry-output entries))
      (is (string= (path real "a-png.png") (ic:entry-output (first entries)))))))
