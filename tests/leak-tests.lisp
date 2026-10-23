;;;; leak-tests.lisp -- no file written carries memory IM never set.
;;;;
;;;; tecgraf-im 2.2.1 and earlier wrote heap memory into files: the padding at
;;;; the end of each line of a BMP, ICO, PCX or Sun raster, and the GIF
;;;; "interlaced" flag.  Whatever the heap held -- a password, a key, another
;;;; image -- left the machine inside a picture that decodes correctly.  The fix
;;;; is in IM (lispnik/tecgraf-im, test/test_uninit.cpp), and this is here
;;;; because the application bundles whichever IM it is built against: it
;;;; fails while that IM is one without the fix.
;;;;
;;;; It needs MallocScribble=1, which `make test` sets: macOS then fills
;;;; every new heap block with 0xAA (MallocPreScribble alone does nothing on
;;;; macOS 26), so a byte IM did not set is 0xAA in the file.  Without it a new
;;;; block is commonly zeros, and these would pass whatever IM did, so they are
;;;; skipped instead.  IM's own test also covers the stack, which no setting
;;;; here can fill.

(in-package #:image-converter/tests)

(def-suite leak-tests :in all-tests)
(in-suite leak-tests)

(defun heap-filled-p ()
  (equal (uiop:getenv "MallocScribble") "1"))

(defun make-black-sample (path kind)
  "Write a black 37x23 image to PATH: KIND is :RGB or :GRAY.  37 wide so that
no line is a multiple of 2 or 4 bytes, and every format here pads it."
  (ensure-directories-exist (native-pathname path))
  (im:with-image (image (im:create 37 23 (ecase kind
                                           (:rgb :color-space-rgb)
                                           (:gray :color-space-gray))
                                   :data-type-byte))
    ;; Cleared, not left as created: the data is a heap block too, and with
    ;; the heap filled it would be 0xAA itself.
    (im:clear image)
    (im:save image (native-pathname path) :format "PNG"))
  path)

(defun file-octets (path)
  (with-open-file (in (native-pathname path) :element-type '(unsigned-byte 8))
    (let ((octets (make-array (file-length in) :element-type '(unsigned-byte 8))))
      (read-sequence octets in)
      octets)))

(test no-padding-is-taken-from-the-heap
  (if (not (heap-filled-p))
      (skip "MallocScribble=1 is not set; `make test` sets it.")
      (with-temporary-directory (dir)
        ;; RGB, which none of these writes a palette for: a palette of grays
        ;; has #xAA in it as a matter of course.  Gray lines are padded by
        ;; the same code, so they need no test of their own.
        (let ((input (make-black-sample (path dir "black.png") :rgb)))
          (dolist (format '("BMP" "ICO" "RAS" "PCX"))
            (let* ((output (path dir (format nil "black.~(~a~)" format)))
                   (octets (progn (ic:convert-file input output format :compression "NONE")
                                  (file-octets output)))
                   ;; PCX's 128-byte header carries the 16-colour VGA
                   ;; palette, which has #xAA in it.
                   (start (if (string= format "PCX") 128 0)))
              ;; Black pixels and these headers have no #xAA in them: any
              ;; there is memory IM did not set.
              (is (not (find #xAA octets :start start))
                  "~a from a black image has bytes IM never set: ~
                   the IM in use leaks heap memory into files"
                  format)))))))

(test gif-interlacing-is-not-taken-from-the-heap
  (if (not (heap-filled-p))
      (skip "MallocScribble=1 is not set; `make test` sets it.")
      (with-temporary-directory (dir)
        (let ((input (make-black-sample (path dir "gray.png") :gray))
              (output (path dir "gray.gif")))
          (ic:convert-file input output "GIF")
          ;; Header, screen descriptor and the image descriptor's separator,
          ;; position and size are 22 bytes; the next is its flags, and #x40
          ;; is "interlaced", which nothing here asks for.
          (let ((octets (file-octets output)))
            (is (= (char-code #\,) (aref octets 13)))
            (is (zerop (logand #x40 (aref octets 22)))
                "the GIF came out interlaced unasked: the IM in use takes ~
                 the flag from heap memory it never set"))))))
