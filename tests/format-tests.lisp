;;;; format-tests.lisp -- the drop-down's list of formats.

(in-package #:image-converter/tests)

(def-suite formats :in all-tests :description "What IM can write.")
(in-suite formats)

(test the-everyday-formats-are-offered
  (let ((names (mapcar #'ic:output-format-name (ic:output-formats))))
    (dolist (name '("PNG" "JPEG" "TIFF" "GIF" "BMP"))
      (is (member name names :test #'string=) "~a is missing from ~s" name names))))

(test the-formats-are-exactly-im-s
  (is (equal (im:format-list) (mapcar #'ic:output-format-name (ic:output-formats)))))

(test extensions-are-parsed-from-im-s-patterns
  (is (equal '("tif" "tiff") (ic::parse-extensions "*.tif;*.tiff;")))
  (is (equal '("png") (ic::parse-extensions "*.png")))
  (is (equal '() (ic::parse-extensions "")))
  (is (equal '("jpg" "jpeg") (ic::parse-extensions "*.JPG; *.jpeg;"))))

(test the-written-extension-is-the-first-listed
  (is (string= "png" (ic:output-format-extension (format-named "PNG"))))
  (is (string= "jpg" (ic:output-format-extension (format-named "JPEG"))))
  (is (string= "tif" (ic:output-format-extension (format-named "TIFF")))))

(test every-format-has-a-title-and-an-extension
  (dolist (format (ic:output-formats))
    (is (search (ic:output-format-name format) (ic:output-format-title format)))
    (is (plusp (length (ic:output-format-extension format))))))

(test image-extensions-cover-the-aliases
  (let ((extensions (ic:image-extensions)))
    (dolist (extension '("png" "jpg" "jpeg" "tif" "tiff" "gif"))
      (is (member extension extensions :test #'string=)))))

(test find-output-format-ignores-case
  (is (string= "PNG" (ic:output-format-name (ic:find-output-format "png"))))
  (is (null (ic:find-output-format "NOT-A-FORMAT"))))
