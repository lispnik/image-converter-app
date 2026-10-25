;;;; format-tests.lisp -- the drop-down's list of formats.

(in-package #:image-converter/tests)

(def-suite formats :in all-tests :description "What IM can write.")
(in-suite formats)

(test the-everyday-formats-are-offered
  (let ((names (mapcar #'ic:output-format-name (ic:output-formats))))
    (dolist (name '("PNG" "JPEG" "TIFF" "GIF" "BMP"))
      (is (member name names :test #'string=) "~a is missing from ~s" name names))))

(test the-formats-are-exactly-im-s
  (is (equal (im:format-list) (mapcar #'ic:output-format-name (ic:input-formats))))
  (is (subsetp (mapcar #'ic:output-format-name (ic:output-formats)) (im:format-list)
               :test #'string=)))

(defun loaded-p (library)
  (im:library-loaded-p library))

(test the-formats-of-im-2-3-are-offered-when-loaded
  (let ((names (mapcar #'ic:output-format-name (ic:output-formats))))
    (loop for (library format) in '((im::lib-im-webp "WEBP") (im::lib-im-jxl "JXL")
                                    (im::lib-im-exr "EXR") (im::lib-im-fits "FITS"))
          when (loaded-p library)
            do (is (member format names :test #'string=) "~a is not offered" format))
    (dolist (format '("QOI" "HDR"))
      (when (member format (im:format-list) :test #'string=)
        (is (member format names :test #'string=) "~a is not offered" format)))))

(test camera-raw-is-read-but-not-offered
  (if (not (loaded-p 'im::lib-im-camraw))
      (skip "libim_camraw is not loaded")
      (progn
        (is (not (ic:find-output-format "CAMRAW")))
        (is (find "CAMRAW" (ic:input-formats) :key #'ic:output-format-name
                                              :test #'string=))
        (dolist (extension '("dng" "cr2" "nef" "arw"))
          (is (member extension (ic:image-extensions) :test #'string=)
              "~a files are not picked up" extension)))))

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
