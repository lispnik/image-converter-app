;;;; convert-tests.lisp -- one file into each format.

(in-package #:image-converter/tests)

(def-suite convert :in all-tests :description "Converting a file.")
(in-suite convert)

(defun output-for (dir name format)
  (path dir "out" (format nil "~a.~a" name (ic:output-format-extension format))))

(test an-rgb-image-converts-to-every-format
  (with-temporary-directory (dir)
    (let ((input (make-sample (path dir "in.png"))))
      (dolist (format (ic:output-formats))
        (let ((output (output-for dir "rgb" format)))
          (handler-case
              (progn
                (ic:convert-file input output (ic:output-format-name format))
                (is (file-exists-p output) "~a: no file" (ic:output-format-name format))
                (multiple-value-bind (width height) (load-back output)
                  (is (= 32 width) "~a: width ~a" (ic:output-format-name format) width)
                  (is (= 24 height) "~a: height ~a" (ic:output-format-name format) height)))
            (error (condition)
              (fail "~a: ~a" (ic:output-format-name format) condition))))))))

(test palette-gray-and-alpha-images-convert-to-every-format
  (with-temporary-directory (dir)
    (dolist (kind '(:map :gray :rgba))
      (let ((input (make-sample (path dir (format nil "~(~a~).png" kind)) :kind kind)))
        (dolist (format (ic:output-formats))
          (let ((output (output-for dir (format nil "~(~a~)" kind) format)))
            (handler-case
                (progn (ic:convert-file input output (ic:output-format-name format))
                       (is (file-exists-p output)))
              (error (condition)
                (fail "~a to ~a: ~a" kind (ic:output-format-name format) condition)))))))))

;;; Width and height alone once passed for an image that came out black: every
;;; 8-bit image with alpha written to a format without it -- PNG to GIF, BMP,
;;; ... -- lost its picture, because IM's colour space conversion copies nothing
;;; between images of the same space.  So the samples are compared too.

(defun gray-samples (path)
  "The image at PATH as 8-bit grayscale samples, and its data type as loaded."
  (im:with-image (loaded (im:load (native-pathname path)))
    ;; Anything wider than a byte is scaled by its own range first: a KRN
    ;; holds 0-255 in 32-bit integers, which scaled from the integer's full
    ;; range would all be 0.
    (im:with-image (image (if (eq (im:data-type loaded) :data-type-byte)
                              (im:duplicate loaded)
                              (im:convert-to-bitmap
                               loaded (im:create (im:width loaded) (im:height loaded)
                                                 (im:color-space loaded) :data-type-byte)
                               :cast-mode :min-max)))
     (im:with-image (gray (ic::reshape image :color-space-gray :data-type-byte nil))
      (let* ((count (* (im:width gray) (im:height gray)))
             (samples (make-array count :element-type '(unsigned-byte 8)))
             (pointer (im:plane-pointer gray 0)))
        (dotimes (i count) (setf (aref samples i) (cffi:mem-aref pointer :uint8 i)))
        (values samples (im:data-type loaded)))))))

(defun mean-difference (a b)
  (/ (loop for x across a for y across b sum (abs (- x y))) (max 1 (length a))))

(test every-kind-keeps-its-picture-in-every-format
  (with-temporary-directory (dir)
    (dolist (kind '(:rgb :rgba :map :gray))
      (let* ((input (make-sample (path dir (format nil "~(~a~).png" kind)) :kind kind))
             (original (gray-samples input)))
        (dolist (format (ic:output-formats))
          (let ((name (ic:output-format-name format))
                (output (output-for dir (format nil "~(~a~)" kind) format)))
            (handler-case
                (progn
                  (ic:convert-file input output name)
                  (multiple-value-bind (samples type) (gray-samples output)
                    (declare (ignore type))
                    (let ((difference (mean-difference original samples)))
                      (is (< difference 24) "~a to ~a: off by ~,1f a sample on average"
                          kind name difference))))
              (error (condition)
                (fail "~a to ~a: ~a" kind name condition)))))))))

(test nothing-is-noted-when-nothing-changed
  (with-temporary-directory (dir)
    (let ((input (make-sample (path dir "in.png"))))
      (is (null (ic:convert-file input (path dir "out.tif") "TIFF")))
      (is (eq :color-space-rgb (nth-value 2 (load-back (path dir "out.tif"))))))))

(test rgb-to-gif-becomes-a-palette-and-says-so
  (with-temporary-directory (dir)
    (let* ((input (make-sample (path dir "in.png")))
           (note (ic:convert-file input (path dir "out.gif") "GIF")))
      (is (search "palette" note))
      (is (eq :color-space-map (nth-value 2 (load-back (path dir "out.gif"))))))))

(test a-palette-to-jpeg-becomes-rgb
  (with-temporary-directory (dir)
    (let* ((input (make-sample (path dir "in.gif") :kind :map))
           (note (ic:convert-file input (path dir "out.jpg") "JPEG")))
      (is (search "RGB" note))
      (is (eq :color-space-rgb (nth-value 2 (load-back (path dir "out.jpg"))))))))

(test alpha-is-kept-where-the-format-has-it
  (with-temporary-directory (dir)
    (let ((input (make-sample (path dir "in.png") :kind :rgba)))
      (ic:convert-file input (path dir "out.tif") "TIFF")
      (is-true (nth-value 3 (load-back (path dir "out.tif")))))))

(test alpha-is-dropped-for-jpeg-and-says-so
  (with-temporary-directory (dir)
    (let* ((input (make-sample (path dir "in.png") :kind :rgba))
           (note (ic:convert-file input (path dir "out.jpg") "JPEG")))
      (is (search "alpha" note))
      (is-false (nth-value 3 (load-back (path dir "out.jpg")))))))

(test the-output-folder-is-made
  (with-temporary-directory (dir)
    (let ((input (make-sample (path dir "in.png"))))
      (ic:convert-file input (path dir "a" "b" "c" "out.bmp") "BMP")
      (is (file-exists-p (path dir "a" "b" "c" "out.bmp"))))))

(test a-file-that-is-not-an-image-is-an-error
  (with-temporary-directory (dir)
    (let ((input (write-text (path dir "fake.png") "this is not a PNG")))
      (signals error (ic:convert-file input (path dir "out.jpg") "JPEG"))
      (is (not (file-exists-p (path dir "out.jpg")))))))

(test ico-says-why-a-large-image-will-not-fit
  (with-temporary-directory (dir)
    (let ((input (make-sample (path dir "big.png") :width 300 :height 20)))
      (handler-case (progn (ic:convert-file input (path dir "out.ico") "ICO")
                           (fail "a 300 pixel wide ICO was written"))
        (error (condition)
          (is (search "255" (princ-to-string condition)))))
      (is (not (file-exists-p (path dir "out.ico")))))))

;;; Settings: compression and quality ------------------------------------------------

(defun file-size (path)
  (with-open-file (stream (native-pathname path) :element-type '(unsigned-byte 8))
    (file-length stream)))

(defun file-compression (path)
  (getf (im:file-info (native-pathname path)) :compression))

(test the-compressions-offered-are-the-ones-that-can-be-written
  (let ((tiff (ic:compression-choices "TIFF")))
    (is (assoc "LZW" tiff :test #'string=))
    (is (assoc "NONE" tiff :test #'string=))
    (is (assoc "JPEG" tiff :test #'string=))
    ;; Listed by IM, and refused by it whatever the image.
    (is (null (assoc "THUNDERSCAN" tiff :test #'string=)))
    (is (null (assoc "SGILOG" tiff :test #'string=)))
    ;; Fax compressions take black and white alone, and say so.
    (is (string= "CCITTFAX4 (black and white only)"
                 (cdr (assoc "CCITTFAX4" tiff :test #'string=)))))
  (is (equal '(("JPEG" . "JPEG")) (ic:compression-choices "JPEG"))))

(test the-compression-chosen-is-the-one-written
  (with-temporary-directory (dir)
    (let ((input (make-sample (path dir "in.png"))))
      (dolist (compression '("NONE" "LZW" "ADOBEDEFLATE"))
        (let ((output (path dir (format nil "~a.tif" compression))))
          (ic:convert-file input output "TIFF" :compression compression)
          (is (string= compression (file-compression output))))))))

(test a-fax-compression-makes-the-image-black-and-white-and-says-so
  (with-temporary-directory (dir)
    (let* ((input (make-sample (path dir "in.png")))
           (note (ic:convert-file input (path dir "out.tif") "TIFF" :compression "CCITTFAX4")))
      (is (search "black and white" note))
      (is (search "CCITTFAX4" note))
      (is (eq :color-space-binary (nth-value 2 (load-back (path dir "out.tif"))))))))

(test quality-changes-the-size
  (with-temporary-directory (dir)
    (let ((input (make-sample (path dir "in.png") :width 256 :height 256)))
      (flet ((size-at (format compression quality extension)
               (let ((output (path dir (format nil "~a-~d.~a" format quality extension))))
                 (ic:convert-file input output format :compression compression :quality quality)
                 (file-size output))))
        (is (< (size-at "JPEG" nil 10 "jpg") (size-at "JPEG" nil 95 "jpg")))
        (is (< (size-at "HEIF" nil 10 "heic") (size-at "HEIF" nil 95 "heic")))
        (is (< (size-at "TIFF" "JPEG" 10 "tif") (size-at "TIFF" "JPEG" 95 "tif")))))))

(test lossless-heif-keeps-the-picture
  (with-temporary-directory (dir)
    (let ((input (make-sample (path dir "in.png") :width 64 :height 64 :kind :gray)))
      (ic:convert-file input (path dir "low.heic") "HEIF" :quality 1)
      (ic:convert-file input (path dir "exact.heic") "HEIF" :lossless t)
      (let ((original (gray-samples input)))
        (is (< (mean-difference original (gray-samples (path dir "exact.heic"))) 1))
        (is (> (mean-difference original (gray-samples (path dir "low.heic")))
               (mean-difference original (gray-samples (path dir "exact.heic")))))))))

(test settings-that-do-not-apply-are-ignored
  (with-temporary-directory (dir)
    (let ((input (make-sample (path dir "in.png"))))
      (is (null (ic:convert-file input (path dir "out.png") "PNG" :quality 5 :lossless t)))
      (is (= 32 (load-back (path dir "out.png")))))))

(test settings-text-says-what-applies
  (is (string= "PNG" (ic:settings-text "PNG")))
  (is (string= "JPEG, quality 60" (ic:settings-text "JPEG" :quality 60)))
  (is (string= "TIFF, LZW compression" (ic:settings-text "TIFF" :compression "LZW" :quality 60)))
  (is (string= "TIFF, JPEG compression, quality 60"
               (ic:settings-text "TIFF" :compression "JPEG" :quality 60)))
  (is (string= "HEIF, lossless" (ic:settings-text "HEIF" :quality 60 :lossless t))))
