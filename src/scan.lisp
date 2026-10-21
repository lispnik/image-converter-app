;;;; scan.lisp -- finding the images in a folder.
;;;;
;;;; Paths are native namestrings throughout, not Lisp pathnames: a file named
;;;; "a*b.png" or "[1].jpg" is ordinary on macOS and a wildcard to PARSE-NAMESTRING.

(in-package #:image-converter)

(defun native (pathname)
  (sb-ext:native-namestring pathname))

(defun directory-name (path)
  "PATH, a native namestring, as a directory pathname."
  (let ((path (string-right-trim "/" path)))
    (sb-ext:parse-native-namestring (concatenate 'string (if (string= path "") "/" path) "/"))))

(defun canonical-path (path)
  "PATH, a native path to a folder, with any symbolic links in it resolved and
no trailing slash.  A folder not made yet -- the output, before the first run --
is resolved through its nearest parent that does exist.

Paths are compared as strings everywhere else, and /tmp is a link to
/private/tmp: without this, an output folder of /tmp/x and an input folder of
/private/tmp/x are different folders, though they are the same one."
  (let ((path (string-right-trim "/" path)))
    (cond ((zerop (length path)) "/")
          ((let ((found (ignore-errors (probe-file (directory-name path)))))
             (and found (string-right-trim "/" (native found)))))
          (t
           (let ((slash (position #\/ path :from-end t)))
             (if (null slash)
                 path
                 (concatenate 'string
                              (string-right-trim "/" (canonical-path (subseq path 0 slash)))
                              "/" (subseq path (1+ slash)))))))))

(defun file-extension (path)
  "The text after the last dot of PATH's last component, lower case, or NIL."
  (let* ((name (subseq path (1+ (or (position #\/ path :from-end t) -1))))
         (dot (position #\. name :from-end t)))
    (and dot (plusp dot) (< (1+ dot) (length name))
         (string-downcase (subseq name (1+ dot))))))

(defun image-file-p (path &optional (extensions (image-extensions)))
  "Whether PATH has the extension of a format IM knows."
  (let ((extension (file-extension path)))
    (and extension (member extension extensions :test #'string=) t)))

(defun hidden-name-p (path)
  (let ((name (subseq path (1+ (or (position #\/ (string-right-trim "/" path) :from-end t) -1)))))
    (and (plusp (length name)) (char= #\. (char name 0)))))

(defun inside-directory-p (path directory)
  "Whether native PATH is DIRECTORY or somewhere beneath it."
  (let ((directory (string-right-trim "/" directory))
        (path (string-right-trim "/" path)))
    (and (>= (length path) (length directory))
         (string= directory path :end2 (length directory))
         (or (= (length path) (length directory))
             (char= #\/ (char path (length directory)))))))

(defun scan-directory (directory &key recursive exclude (extensions (image-extensions)))
  "The image files in DIRECTORY, a native path, as sorted native paths, which
begin with DIRECTORY's CANONICAL-PATH.

With RECURSIVE, its subdirectories too. Hidden files and folders are passed
over, and so is anything inside EXCLUDE: the output folder, when it is inside
the input folder, so that converting twice does not list the first run's output
as input. Symbolic links to folders are not followed, which is what keeps a link
back to a parent from making the walk endless."
  (let ((root (directory-name (canonical-path directory)))
        (exclude (and exclude (canonical-path exclude)))
        (found '()))
    (labels ((walk (dir)
               (dolist (entry (ignore-errors
                               (directory (merge-pathnames uiop:*wild-file-for-directory* dir)
                                          :resolve-symlinks nil)))
                 (let ((path (native entry)))
                   (cond ((hidden-name-p path))
                         ((and exclude (inside-directory-p path exclude)))
                         ((uiop:directory-pathname-p entry)
                          (when (and recursive
                                     ;; A link to a folder is listed as a folder.
                                     (not (symlink-p path)))
                            (walk entry)))
                         ((image-file-p path extensions)
                          (push path found)))))))
      (when (uiop:directory-exists-p root)
        (walk root)))
    (sort found #'string<)))

(defun symlink-p (path)
  (let ((path (string-right-trim "/" path)))
    (ignore-errors
     (eq :symlink (sb-impl::native-file-kind path)))))

(defun relative-name (path directory)
  "PATH, which is inside DIRECTORY, relative to it.  DIRECTORY may be written
as it was typed or as its CANONICAL-PATH, which is how SCAN-DIRECTORY answers."
  (flet ((under (directory)
           (let ((directory (concatenate 'string (string-right-trim "/" directory) "/")))
             (and (> (length path) (length directory))
                  (string= directory path :end2 (length directory))
                  (subseq path (length directory))))))
    (or (under directory)
        (under (canonical-path directory))
        path)))
