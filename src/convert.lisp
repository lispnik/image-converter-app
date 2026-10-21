;;;; convert.lisp -- one file into another format.
;;;;
;;;; IM writes an image only in the colour spaces and sample types the format
;;;; can store, and says DATA-ERROR otherwise: a GIF must be a palette image, a
;;;; JPEG cannot be one, PFM holds only floats.  Saving the loaded image as it
;;;; is therefore fails for about a third of the pairs of everyday formats.
;;;;
;;;; So the image is first fitted to the format.  IM is asked, without writing
;;;; anything, whether the format can store each of a short list of shapes --
;;;; the image as it is first -- and the image is converted to the first one it
;;;; can.  What was done is reported, so that the details say "converted to
;;;; palette colour" rather than leaving a smaller file to be puzzled over.

(in-package #:image-converter)

(defparameter *fallback-shapes*
  '((:color-space-rgb :data-type-byte)
    (:color-space-map :data-type-byte)
    (:color-space-gray :data-type-byte)
    (:color-space-gray :data-type-int)
    (:color-space-rgb :data-type-float)
    (:color-space-gray :data-type-float)
    (:color-space-binary :data-type-byte))
  "What to try, in order, when a format cannot store an image as it is.  Each
is a colour space and a sample type, without alpha: the formats that refuse an
image commonly refuse its alpha channel too.")

(defun color-mode-value (color-space alpha)
  "IM's packed colour mode: the space, and the alpha bit."
  (logior (cffi:foreign-enum-value 'im.ffi::color-space color-space)
          (if alpha (cffi:foreign-bitfield-value 'im.ffi::color-mode-config
                                                 '(:color-mode-config-alpha))
              0)))

(defun default-compression (format-name)
  "The compression IM uses when none is asked for: the first it lists."
  (or (first (ignore-errors (im:format-compressions format-name))) ""))

(defun can-write-p (format-name color-space data-type alpha)
  (im:format-can-write-p format-name (default-compression format-name)
                         (color-mode-value color-space alpha)
                         (cffi:foreign-enum-value 'im.ffi::data-type data-type)))

(defun candidate-shapes (image format-name)
  "The shapes -- colour space, sample type, alpha -- IMAGE may be written in as
FORMAT-NAME, best first: its own, its own less alpha, then the fallbacks, each
only if IM says the format can store it."
  (let* ((space (im:color-space image))
         (type (im:data-type image))
         (alpha (im:has-alpha-p image))
         (shapes (append (list (list space type alpha))
                         (and alpha (list (list space type nil)))
                         (loop for (s tp) in *fallback-shapes* collect (list s tp nil)))))
    (remove-if-not (lambda (shape) (apply #'can-write-p format-name shape))
                   (remove-duplicates shapes :test #'equal :from-end t))))

(defun shape-name (color-space data-type)
  (format nil "~a ~a"
          (ecase color-space
            (:color-space-rgb "RGB colour")
            (:color-space-map "palette colour")
            (:color-space-gray "grayscale")
            (:color-space-binary "black and white")
            (:color-space-cmyk "CMYK colour")
            (:color-space-ycbcr "YCbCr colour")
            (:color-space-lab "Lab colour")
            (:color-space-luv "Luv colour")
            (:color-space-xyz "XYZ colour"))
          (ecase data-type
            (:data-type-byte "(8-bit)")
            (:data-type-short "(16-bit signed)")
            (:data-type-ushort "(16-bit)")
            (:data-type-int "(32-bit integer)")
            (:data-type-float "(32-bit float)")
            (:data-type-double "(64-bit float)")
            (:data-type-cfloat "(complex float)")
            (:data-type-cdouble "(complex double)"))))

(defun reshape (image color-space data-type alpha)
  "A new image holding IMAGE as COLOR-SPACE and DATA-TYPE, with ALPHA or not.
The caller destroys it.  Goes by way of an 8-bit image, which is the shape IM's
colour conversions are written for."
  (let ((owned '()))
    (flet ((own (new) (push new owned) new))
      (handler-bind ((error (lambda (condition)
                              (declare (ignore condition))
                              (mapc #'im:destroy owned))))
        (let* ((width (im:width image))
               (height (im:height image))
               ;; 8-bit RGB or gray first, whatever it was.
               (bitmap (if (and (im:bitmap-p image) (not (im:has-alpha-p image)))
                           image
                           (let ((space (if (member (im:color-space image)
                                                    '(:color-space-gray :color-space-binary))
                                            :color-space-gray
                                            :color-space-rgb)))
                             ;; A 16-bit photo keeps its contrast: integer
                             ;; samples are scaled from their type's full
                             ;; range.  Floats have no such range, and are
                             ;; scaled from the image's own.
                             (im:convert-to-bitmap
                              image (own (im:create width height space :data-type-byte))
                              :cast-mode (if (member (im:data-type image)
                                                     '(:data-type-float :data-type-double
                                                       :data-type-cfloat :data-type-cdouble))
                                             :min-max
                                             :fixed)))))
               ;; Then the colour space, still 8-bit.
               (spaced (if (eq (im:color-space bitmap) color-space)
                           bitmap
                           (im:convert-color-space
                            bitmap (own (im:create width height color-space :data-type-byte)))))
               ;; Then the sample type.
               (typed (if (eq data-type :data-type-byte)
                          spaced
                          ;; Upwards from 8 bits, so the values are kept.
                          (im:convert-data-type
                           spaced (own (im:create width height color-space data-type))
                           :cast-mode :direct))))
          (when alpha
            (im.ffi::%im-image-add-alpha (im:handle typed)))
          ;; Everything made on the way but the answer.
          (dolist (image (remove typed owned))
            (im:destroy image))
          (if (eq typed image)
              (im:duplicate image)
              typed))))))

(defun delete-partial-output (path)
  "IM may leave a truncated file behind when a write fails."
  (ignore-errors (delete-file (sb-ext:parse-native-namestring path))))

(defparameter *size-limits*
  '(("ICO" . 255))
  "Formats that hold images no wider or taller than so many pixels.  IM says
only \"invalid or unsupported image data\" when one is exceeded.")

(defun size-problem (image format-name)
  (let ((limit (cdr (assoc format-name *size-limits* :test #'string-equal))))
    (when (and limit (or (> (im:width image) limit) (> (im:height image) limit)))
      (format nil "~a holds images up to ~d by ~d pixels, and this one is ~d by ~d."
              format-name limit limit (im:width image) (im:height image)))))

(defun shape-note (image shape format-name)
  "What was changed to write IMAGE as SHAPE, or NIL if nothing was."
  (destructuring-bind (space type alpha) shape
    (let ((lost-alpha (and (im:has-alpha-p image) (not alpha))))
      (cond ((not (and (eq space (im:color-space image))
                       (eq type (im:data-type image))))
             (format nil "Converted from ~a to ~a~:[~;, without alpha,~] ~
                          because ~a cannot store the original."
                     (shape-name (im:color-space image) (im:data-type image))
                     (shape-name space type) lost-alpha format-name))
            (lost-alpha
             (format nil "The alpha channel was dropped because ~a cannot store it."
                     format-name))))))

(defun written-shape (image shape output)
  "SHAPE, less the alpha channel if OUTPUT turns out not to have one.  IM's
answer to whether a format can store alpha is always yes, and JPEG and PNM then
drop it without a word; the file's header is the only place that says so."
  (destructuring-bind (space type alpha) shape
    (if (and alpha (im:has-alpha-p image))
        (let ((frame (first (getf (ignore-errors
                                   (im:file-info (sb-ext:parse-native-namestring output)))
                                  :frames))))
          (list space type (and (or (null frame)
                                    (member :color-mode-config-alpha
                                            (getf frame :color-mode-config)))
                                t)))
        shape)))

(defun write-shape (image shape output format-name)
  (destructuring-bind (space type alpha) shape
    (if (and (eq space (im:color-space image))
             (eq type (im:data-type image))
             (eq alpha (im:has-alpha-p image)))
        (im:save image (sb-ext:parse-native-namestring output) :format format-name)
        (im:with-image (fitted (reshape image space type alpha))
          (im:save fitted (sb-ext:parse-native-namestring output) :format format-name)))))

(defun convert-file (input output format-name)
  "Read the image in INPUT and write it to OUTPUT as FORMAT-NAME.  Both are
native paths; OUTPUT's folder is made if need be.

Returns a note of what had to be changed to fit the format, or NIL when the
image went in as it was.  Signals an error, with a message fit to show, when
the file cannot be read, has nothing the format can store, or cannot be written.

IM's answer to whether a format can store a shape is not the last word: a
format may still refuse the data when it is written.  So each shape it accepts
is tried in turn, and only the last refusal is reported."
  (ensure-directories-exist (sb-ext:parse-native-namestring output))
  (im:with-image (image (im:load (sb-ext:parse-native-namestring input)))
    (let ((problem (size-problem image format-name))
          (shapes (candidate-shapes image format-name))
          (last-error nil))
      (when problem
        (error "~a" problem))
      (unless shapes
        (error "~a cannot store a ~a image."
               format-name (shape-name (im:color-space image) (im:data-type image))))
      (dolist (shape shapes)
        (handler-case
            (progn (write-shape image shape output format-name)
                   (return-from convert-file
                     (shape-note image (written-shape image shape output) format-name)))
          (im:data-error (condition)
            (delete-partial-output output)
            (setf last-error condition))
          (error (condition)
            (delete-partial-output output)
            (error condition))))
      (error last-error))))
