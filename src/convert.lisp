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
  (or (first (format-compressions* format-name)) ""))

(defun can-write-p (format-name color-space data-type alpha &optional compression)
  (im:format-can-write-p format-name (or compression (default-compression format-name))
                         (color-mode-value color-space alpha)
                         (cffi:foreign-enum-value 'im.ffi::data-type data-type)))

;;; Settings: compression and quality ---------------------------------------------
;;;
;;; The compression is IM's: each format lists its own, and SAVE takes one by
;;; name.  Quality is not, and has no common name: each driver reads an image
;;; attribute of its own when it writes, and quietly ignores one it does not
;;; know.  So which formats have it, and what it is called, is written down here.

(defparameter *quality-attributes*
  '(("JPEG" "JPEGQuality" 75)
    ("HEIF" "Quality" 80)
    ("AVIF" "Quality" 80))
  "Format, the attribute its driver reads quality from (0 to 100), and IM's
default.  TIFF reads JPEGQuality too, when its compression is JPEG.")

(defparameter *lossless-formats* '("HEIF" "AVIF")
  "The formats whose driver reads a Lossless attribute.")

(defun quality-attribute (format-name &optional compression)
  "The attribute FORMAT-NAME, written with COMPRESSION, takes its quality from,
and its default, or NIL if it has no quality to set."
  (let ((entry (assoc format-name *quality-attributes* :test #'string-equal)))
    (cond (entry (values (second entry) (third entry)))
          ((and (string-equal format-name "TIFF") (equalp compression "JPEG"))
           (values "JPEGQuality" 75)))))

(defun lossless-available-p (format-name)
  (and (member format-name *lossless-formats* :test #'string-equal) t))

(defun shape-only-name (color-space)
  (ecase color-space
    (:color-space-rgb "colour")
    (:color-space-map "palette")
    (:color-space-gray "grayscale")
    (:color-space-binary "black and white")))

(defun compression-choices (format-name)
  "The compressions FORMAT-NAME can be written with, as (NAME . TITLE), in IM's
order.  Those IM lists and cannot write -- TIFF's NEXT, THUNDERSCAN, SGILOG --
are left out.  One that takes only some images says which in its title: TIFF's
CCITT ones store black and white alone, so choosing one makes every image that."
  (loop for name in (format-compressions* format-name)
        for writable = (loop for (space type) in *fallback-shapes*
                             when (can-write-p format-name space type nil name)
                               collect space)
        when writable
          collect (cons name
                        (if (member :color-space-rgb writable)
                            name
                            (format nil "~a (~a only)" name
                                    (shape-only-name (first writable)))))))

(defun apply-settings (image format-name &key compression quality lossless)
  "Set on IMAGE the attributes FORMAT-NAME's driver reads its QUALITY and
LOSSLESS from, where it has them."
  (let ((attribute (quality-attribute format-name compression)))
    (when (and attribute quality)
      (im:set-image-attribute image attribute (max 0 (min 100 (round quality))))))
  (when (and lossless (lossless-available-p format-name))
    (im:set-image-attribute image "Lossless" 1))
  image)

(defun settings-text (format-name &key compression quality lossless)
  "The settings, as the details say them: \"TIFF, JPEG compression, quality 60\"."
  (format nil "~a~@[, ~a compression~]~:[~@[, quality ~d~]~;~*, lossless~]"
          format-name compression
          (and lossless (lossless-available-p format-name))
          (and quality (quality-attribute format-name compression) (round quality))))

(defun candidate-shapes (image format-name &optional compression)
  "The shapes -- colour space, sample type, alpha -- IMAGE may be written in as
FORMAT-NAME with COMPRESSION, best first: its own, its own less alpha, then the
fallbacks, each only if IM says the format can store it."
  (let* ((space (im:color-space image))
         (type (im:data-type image))
         (alpha (im:has-alpha-p image))
         (shapes (append (list (list space type alpha))
                         (and alpha (list (list space type nil)))
                         (loop for (s tp) in *fallback-shapes* collect (list s tp nil)))))
    (remove-if-not (lambda (shape)
                     (destructuring-bind (space type alpha) shape
                       (can-write-p format-name space type alpha compression)))
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
               (bitmap (cond
                         ((and (im:bitmap-p image) (not (im:has-alpha-p image)))
                          image)
                         ;; Already 8-bit, so only the alpha plane goes.  Not
                         ;; by CONVERT-TO-BITMAP: for 8-bit samples it is
                         ;; IM's colour space conversion, which copies nothing
                         ;; when the space is the same, and the image came out
                         ;; black.
                         ((im:bitmap-p image)
                          (let ((copy (own (im:duplicate image))))
                            (im.ffi::%im-image-remove-alpha (im:handle copy))
                            copy))
                         (t
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
                                             :fixed))))))
               ;; Then the colour space, still 8-bit.
               (spaced (cond ((eq (im:color-space bitmap) color-space)
                              bitmap)
                             ;; To a palette is IM's quantizer, which keeps
                             ;; its working state in statics: one at a time.
                             ((eq color-space :color-space-map)
                              (with-im-lock ()
                                (im:convert-color-space
                                 bitmap (own (im:create width height color-space
                                                        :data-type-byte)))))
                             (t
                              (im:convert-color-space
                               bitmap (own (im:create width height color-space
                                                      :data-type-byte))))))
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

(defun lost-colour-p (shape output)
  "Whether OUTPUT, written as SHAPE in colour, came out gray.  IM says LED can
store RGB, and its writer then keeps the red channel alone; the file's header
is again the only place that says so.  Such a write counts as refused, and the
next shape -- for LED, a palette -- is tried."
  (and (eq (first shape) :color-space-rgb)
       (let ((frame (first (getf (ignore-errors
                                  (im:file-info (sb-ext:parse-native-namestring output)))
                                 :frames))))
         (and frame
              (member (getf frame :color-space) '(:color-space-gray :color-space-binary))
              t))))

;;; The image as loaded is ours to change: the attributes are set on it, or on
;;; the fitted copy, just before it is written.
(defun write-shape (image shape output format-name settings)
  (flet ((save (image)
           (apply #'apply-settings image format-name settings)
           (flet ((write-file ()
                    (im:save image (sb-ext:parse-native-namestring output)
                             :format format-name :compression (getf settings :compression))))
             ;; IM's PNG writer counts its text chunks in a static.
             (if (string-equal format-name "PNG")
                 (with-im-lock () (write-file))
                 (write-file)))))
    (destructuring-bind (space type alpha) shape
      (if (and (eq space (im:color-space image))
               (eq type (im:data-type image))
               (eq alpha (im:has-alpha-p image)))
          (save image)
          (im:with-image (fitted (reshape image space type alpha))
            (save fitted))))))

(defun convert-file (input output format-name &rest settings
                     &key compression quality lossless)
  "Read the image in INPUT and write it to OUTPUT as FORMAT-NAME.  Both are
native paths; OUTPUT's folder is made if need be.  COMPRESSION is one of the
format's, by IM's name, or NIL for its default; QUALITY, 0 to 100, and LOSSLESS
are used by the formats that have them (see APPLY-SETTINGS) and ignored by the
rest.

Returns a note of what had to be changed to fit the format, or NIL when the
image went in as it was.  Signals an error, with a message fit to show, when
the file cannot be read, has nothing the format can store, or cannot be written.

IM's answer to whether a format can store a shape is not the last word: a
format may still refuse the data when it is written.  So each shape it accepts
is tried in turn, and only the last refusal is reported."
  (declare (ignore quality lossless))
  (ensure-directories-exist (sb-ext:parse-native-namestring output))
  (im:with-image (image (im:load (sb-ext:parse-native-namestring input)))
    (let ((problem (size-problem image format-name))
          (shapes (candidate-shapes image format-name compression))
          ;; What the notes and errors call it: the compression, when one was
          ;; chosen, may be what refused the image.
          (described (if compression
                         (format nil "~a with ~a compression" format-name compression)
                         format-name))
          (last-error nil))
      (when problem
        (error "~a" problem))
      (unless shapes
        (error "~a cannot store a ~a image."
               described (shape-name (im:color-space image) (im:data-type image))))
      (dolist (shape shapes)
        (handler-case
            (progn (write-shape image shape output format-name settings)
                   (if (lost-colour-p shape output)
                       (progn
                         (delete-partial-output output)
                         (setf last-error
                               (make-condition 'simple-error
                                               :format-control "~a wrote a colour image as grayscale."
                                               :format-arguments (list described))))
                       (return-from convert-file
                         (shape-note image (written-shape image shape output) described))))
          (im:data-error (condition)
            (delete-partial-output output)
            (setf last-error condition))
          (error (condition)
            (delete-partial-output output)
            (error condition))))
      (error last-error))))
