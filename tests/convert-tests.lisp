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
