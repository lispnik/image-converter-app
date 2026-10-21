;;;; scan-tests.lisp -- which files are listed.

(in-package #:image-converter/tests)

(def-suite scan :in all-tests :description "Finding the images in a folder.")
(in-suite scan)

(defun names (paths directory)
  (mapcar (lambda (path) (ic:relative-name path directory)) paths))

(defun make-tree (directory)
  (write-text (path directory "a.png") "")
  (write-text (path directory "B.JPG") "")
  (write-text (path directory "notes.txt") "")
  (write-text (path directory "noextension") "")
  (write-text (path directory ".hidden.png") "")
  (write-text (path directory "sub" "c.gif") "")
  (write-text (path directory "sub" "deeper" "d.tif") "")
  (write-text (path directory ".git" "e.png") ""))

(test only-the-folder-itself-when-not-recursive
  (with-temporary-directory (dir)
    (make-tree dir)
    (is (equal '("B.JPG" "a.png") (names (ic:scan-directory dir) dir)))))

(test subfolders-too-when-recursive
  (with-temporary-directory (dir)
    (make-tree dir)
    (is (equal '("B.JPG" "a.png" "sub/c.gif" "sub/deeper/d.tif")
               (names (ic:scan-directory dir :recursive t) dir)))))

(test the-output-folder-is-left-out
  (with-temporary-directory (dir)
    (make-tree dir)
    (write-text (path dir "Converted" "a.png") "")
    (write-text (path dir "Converted" "sub" "c.png") "")
    (is (equal '("B.JPG" "a.png" "sub/c.gif" "sub/deeper/d.tif")
               (names (ic:scan-directory dir :recursive t :exclude (path dir "Converted")) dir)))
    ;; A folder whose name merely begins the same is not inside it.
    (write-text (path dir "Converted2" "f.png") "")
    (is (member "Converted2/f.png"
                (names (ic:scan-directory dir :recursive t :exclude (path dir "Converted")) dir)
                :test #'string=))))

(test a-trailing-slash-makes-no-difference
  (with-temporary-directory (dir)
    (make-tree dir)
    (is (equal (ic:scan-directory dir) (ic:scan-directory (concatenate 'string dir "/"))))))

(test a-missing-folder-has-no-images
  (is (null (ic:scan-directory "/no/such/folder/anywhere"))))

(test names-that-look-like-wildcards-are-found
  (with-temporary-directory (dir)
    (write-text (path dir "[1] *what?.png") "")
    (is (equal '("[1] *what?.png") (names (ic:scan-directory dir) dir)))))

(test a-link-back-up-is-not-followed
  (with-temporary-directory (dir)
    (write-text (path dir "sub" "a.png") "")
    (sb-posix:symlink dir (path dir "sub" "loop"))
    (is (equal '("sub/a.png") (names (ic:scan-directory dir :recursive t) dir)))))

(test relative-names
  (is (string= "sub/a.png" (ic:relative-name "/x/y/sub/a.png" "/x/y")))
  (is (string= "sub/a.png" (ic:relative-name "/x/y/sub/a.png" "/x/y/")))
  (is (string= "/elsewhere/a.png" (ic:relative-name "/elsewhere/a.png" "/x/y"))))

(test image-file-p-goes-by-extension
  (is (ic:image-file-p "/x/photo.JPEG"))
  (is (not (ic:image-file-p "/x/photo.txt")))
  (is (not (ic:image-file-p "/x/png")))
  (is (not (ic:image-file-p "/x/photo."))))

;;; The same folder, reached two ways.  /tmp is a link to /private/tmp, and
;;; comparing the two as strings once had the output folder, chosen as /tmp/x,
;;; taken for a different folder from the input, /private/tmp/x -- so the
;;; outputs were written among the inputs and listed as inputs the next time.

(test canonical-paths-resolve-links
  (with-temporary-directory (dir)
    (let ((real (ic::canonical-path dir)))
      (is (string= real (ic::canonical-path (concatenate 'string dir "/"))))
      (is (not (search "/tmp/" real :end2 5)) "~a still begins /tmp/" real)
      ;; A folder not made yet resolves through the parent that is.
      (is (string= (concatenate 'string real "/not/yet")
                   (ic::canonical-path (path dir "not" "yet")))))))

(test an-output-folder-reached-through-a-link-is-still-left-out
  (with-temporary-directory (dir)
    (let ((real (ic::canonical-path dir)))
      (write-text (path dir "a.png") "")
      (write-text (path dir "Converted" "a.png") "")
      (is (equal '("a.png") (names (ic:scan-directory real :recursive t
                                                           :exclude (path dir "Converted"))
                                   dir)))
      (is (equal '("a.png") (names (ic:scan-directory dir :recursive t
                                                          :exclude (path real "Converted"))
                                   dir))))))

(test relative-names-through-a-link
  (with-temporary-directory (dir)
    (write-text (path dir "sub" "a.png") "")
    (is (equal '("sub/a.png") (names (ic:scan-directory dir :recursive t) dir)))
    (is (equal '("sub/a.png") (names (ic:scan-directory dir :recursive t)
                                     (ic::canonical-path dir))))))
