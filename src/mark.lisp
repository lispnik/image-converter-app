;;;; mark.lisp -- knowing the files this application wrote.
;;;;
;;;; Converted with the output folder the input folder, a second run would find
;;;; the first run's output among the originals and convert it again: photo.png
;;;; to JPEG writes photo.jpg, and the next run to JPEG lists photo.jpg as an
;;;; input and writes photo-jpg.jpg beside it.  So each file written is marked
;;;; with an extended attribute naming the file it was converted from, and a
;;;; marked file whose original is in the same list is left out of it.
;;;;
;;;; Only then: a folder of converted files chosen as the input on purpose,
;;;; without the originals, is converted like any other.

(in-package #:image-converter)

(defparameter +source-attribute+ "org.lispnik.image-converter.source"
  "The extended attribute naming, as a native path, the file a file was converted from.")

(cffi:defcfun ("getxattr" %getxattr) :long
  (path :string) (name :string) (value :pointer) (size :unsigned-long)
  (position :uint32) (options :int))

(cffi:defcfun ("setxattr" %setxattr) :int
  (path :string) (name :string) (value :pointer) (size :unsigned-long)
  (position :uint32) (options :int))

(defun mark-converted (output input)
  "Record on the file OUTPUT that it was converted from INPUT.  Answers whether
it could be; a file system without extended attributes is no reason to fail a
conversion that has worked."
  (ignore-errors
   (let ((octets (sb-ext:string-to-octets input :external-format :utf-8)))
     (cffi:with-pointer-to-vector-data (value octets)
       (zerop (%setxattr output +source-attribute+ value (length octets) 0 0))))))

(defun converted-from (path)
  "The native path of the file PATH was converted from, if this application
wrote it; else NIL."
  (ignore-errors
   (let ((size (%getxattr path +source-attribute+ (cffi:null-pointer) 0 0 0)))
     (when (plusp size)
       (let ((octets (make-array size :element-type '(unsigned-byte 8))))
         (let ((read (cffi:with-pointer-to-vector-data (value octets)
                       (%getxattr path +source-attribute+ value size 0 0))))
           (when (= read size)
             (sb-ext:octets-to-string octets :external-format :utf-8))))))))

(defun without-earlier-conversions (paths)
  "PATHS less the files converted from one of PATHS by an earlier run, and how
many were left out.  PATHS are canonical native paths, as SCAN-DIRECTORY answers."
  (let ((listed (make-hash-table :test #'equal)))
    (dolist (path paths)
      (setf (gethash path listed) t))
    (let ((kept (remove-if (lambda (path)
                             (let ((source (converted-from path)))
                               (and source (string/= source path) (gethash source listed))))
                           paths)))
      (values kept (- (length paths) (length kept))))))
