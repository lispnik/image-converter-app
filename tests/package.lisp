;;;; package.lisp -- the test package, the root suite, and what tests share.

(defpackage #:image-converter/tests
  (:use #:common-lisp #:fiveam)
  (:local-nicknames (#:ic #:image-converter))
  (:export #:all-tests #:run-tests))

(in-package #:image-converter/tests)

(def-suite all-tests :description "Everything.")

(defun run-tests ()
  "Run every test and answer whether they all passed."
  (let ((results (run 'all-tests)))
    (explain! results)
    (results-status results)))

;;; Directories to test in ----------------------------------------------------------

(defun call-with-temporary-directory (function)
  ;; Under /tmp on purpose: /tmp is a link to /private/tmp, so every test here
  ;; works on a folder reached through a link, as an external disk's often is.
  (let ((directory (sb-posix:mkdtemp "/tmp/image-converter-test-XXXXXX")))
    (unwind-protect (funcall function directory)
      (uiop:delete-directory-tree
       (sb-ext:parse-native-namestring (concatenate 'string directory "/"))
       :validate (lambda (path)
                   (search "image-converter-test-" (sb-ext:native-namestring path)))
       :if-does-not-exist :ignore))))

(defmacro with-temporary-directory ((directory) &body body)
  "Run BODY with DIRECTORY bound to the native name of a new, empty directory
that is removed afterwards."
  `(call-with-temporary-directory (lambda (,directory) ,@body)))

(defun path (directory &rest names)
  (format nil "~a~{/~a~}" directory names))

(defun native-pathname (path)
  (sb-ext:parse-native-namestring path))

(defun file-exists-p (path)
  (and (probe-file (native-pathname path)) t))

(defun write-text (path contents)
  (ensure-directories-exist (native-pathname path))
  (with-open-file (out (native-pathname path) :direction :output :if-exists :supersede)
    (write-string contents out))
  path)

;;; Images to convert ---------------------------------------------------------------
;;;
;;; Drawn here rather than checked in: a gradient, so that a conversion that
;;; lost the picture would at least not be converting a blank one.

(defun fill-gradient (image)
  (let* ((width (im:width image))
         (height (im:height image))
         (planes (im:depth image)))
    (dotimes (plane planes)
      (let ((pointer (im:plane-pointer image plane)))
        (dotimes (y height)
          (dotimes (x width)
            (setf (cffi:mem-aref pointer :uint8 (+ x (* y width)))
                  (mod (+ (* x 7) (* y 3) (* plane 80)) 256))))))
    image))

(defun make-sample (path &key (width 32) (height 24) (kind :rgb) (format nil))
  "Write an image to PATH: KIND is :RGB, :GRAY, :MAP (palette) or :RGBA."
  (ensure-directories-exist (native-pathname path))
  (im:with-image (rgb (fill-gradient (im:create width height
                                                (if (eq kind :gray) :color-space-gray :color-space-rgb)
                                                :data-type-byte)))
    (ecase kind
      ((:rgb :gray)
       (im:save rgb (native-pathname path) :format format))
      (:rgba
       (im.ffi::%im-image-add-alpha (im:handle rgb))
       (im:save rgb (native-pathname path) :format format))
      (:map
       (im:with-image (map (im:create width height :color-space-map :data-type-byte))
         (im:convert-color-space rgb map)
         (im:save map (native-pathname path) :format format)))))
  path)

(defun load-back (path)
  "Width, height and colour space of the image at PATH."
  (im:with-image (image (im:load (native-pathname path)))
    (values (im:width image) (im:height image) (im:color-space image) (im:has-alpha-p image))))

(defun format-named (name)
  (or (ic:find-output-format name)
      (error "IM has no ~a format here." name)))
