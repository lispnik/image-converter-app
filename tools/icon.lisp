;;;; icon.lisp -- draws res/icon.png, with IM, pixel by pixel.
;;;;
;;;;   make icon
;;;;
;;;; Two pictures, one behind the other, on a blue tile, and an arrow from the
;;;; back one to the front: one image becoming another.  The PNG is checked in,
;;;; so this runs only when the drawing changes; asdf-macos-app makes the .icns.

(defpackage #:image-converter-icon
  (:use #:common-lisp)
  (:export #:main))

(in-package #:image-converter-icon)

(defparameter *size* 1024)

(defun clamp (x) (max 0 (min 255 (round x))))

(defun mix (a b f) (+ a (* (- b a) f)))

(defun rounded-rect-coverage (x y left bottom right top radius)
  "How much of the pixel at X,Y a rounded rectangle covers, 0 to 1, with a
pixel's width of soft edge."
  (let* ((cx (max (+ left radius) (min x (- right radius))))
         (cy (max (+ bottom radius) (min y (- top radius))))
         (d (- (sqrt (+ (expt (- x cx) 2) (expt (- y cy) 2))) radius)))
    (max 0 (min 1 (- 0.5 d)))))

(defun triangle-coverage (x y ax ay bx by cx cy)
  "Coverage of the triangle A B C, by the signed distance to its nearest edge."
  (flet ((edge (px py qx qy)
           (let* ((ex (- qx px)) (ey (- qy py))
                  (len (sqrt (+ (* ex ex) (* ey ey)))))
             (/ (- (* ex (- y py)) (* ey (- x px))) len))))
    ;; Whichever way round the corners are given.
    (let ((d (max (min (edge ax ay bx by) (edge bx by cx cy) (edge cx cy ax ay))
                  (- (max (edge ax ay bx by) (edge bx by cx cy) (edge cx cy ax ay))))))
      (max 0 (min 1 (+ 0.5 d))))))

(defun picture (x y left bottom right top)
  "A landscape inside a frame: sky, a sun, two hills.  Answers (values r g b)
of the picture at X,Y, which is inside it."
  (let* ((u (/ (- x left) (- right left)))
         (v (/ (- y bottom) (- top bottom)))
         (sun (- (sqrt (+ (expt (- u 0.72) 2) (expt (- v 0.72) 2))) 0.11))
         (hill-1 (- v (+ 0.30 (* 0.22 (cos (* 5.0 (- u 0.30)))))))
         (hill-2 (- v (+ 0.18 (* 0.16 (cos (* 4.0 (- u 0.85))))))))
    (cond ((< hill-2 0) (values 46 125 72))
          ((< hill-1 0) (values 76 168 98))
          ((< sun 0) (values 255 196 61))
          (t (values (mix 120 190 v) (mix 180 225 v) 250)))))

(defun shade (x y)
  "The icon at X,Y as (values r g b a); y runs upwards."
  (let ((r 0) (g 0) (b 0) (a 0))
    (flet ((over (cr cg cb coverage)
             (when (plusp coverage)
               (setf r (mix r cr coverage) g (mix g cg coverage) b (mix b cb coverage)
                     a (+ a (* (- 255 a) coverage))))))
      ;; The tile, inset as macOS icons are, with a vertical gradient.
      (let ((tile (rounded-rect-coverage x y 100 100 924 924 185))
            (f (/ y *size*)))
        (over (mix 38 88 f) (mix 84 150 f) (mix 196 240 f) tile))
      ;; The picture behind, faded, up and to the left.
      (let ((frame (rounded-rect-coverage x y 190 380 640 760 36)))
        (when (plusp frame)
          (over 235 240 250 (* 0.85 frame))
          (when (plusp (rounded-rect-coverage x y 214 404 616 736 18))
            (multiple-value-bind (pr pg pb) (picture x y 214 404 616 736)
              (over (mix pr 200 0.45) (mix pg 205 0.45) (mix pb 215 0.45)
                    (* 0.85 (rounded-rect-coverage x y 214 404 616 736 18)))))))
      ;; The picture in front, down and to the right, with a soft shadow.
      (over 10 30 70 (* 0.35 (rounded-rect-coverage x y 392 210 852 600 60)))
      (let ((frame (rounded-rect-coverage x y 384 222 834 602 36)))
        (over 255 255 255 frame)
        (let ((inner (rounded-rect-coverage x y 408 246 810 578 18)))
          (when (plusp inner)
            (multiple-value-bind (pr pg pb) (picture x y 408 246 810 578)
              (over pr pg pb inner)))))
      ;; The arrow, from the one behind to the one in front.
      (let ((shaft (rounded-rect-coverage x y 190 262 300 322 20))
            (head (triangle-coverage x y 286 206 286 378 372 292)))
        (over 255 255 255 (max shaft head))))
    (values (clamp r) (clamp g) (clamp b) (clamp a))))

(defun main (&optional (path "res/icon.png"))
  (im:with-image (image (im:create *size* *size* :color-space-rgb :data-type-byte))
    (im.ffi::%im-image-add-alpha (im:handle image))
    (let ((planes (loop for plane below 4 collect (im:plane-pointer image plane))))
      ;; IM's rows run bottom-up, which is the way y runs here too.
      (dotimes (y *size*)
        (dotimes (x *size*)
          (multiple-value-bind (r g b a) (shade (+ x 0.5) (+ y 0.5))
            (loop for pointer in planes
                  for value in (list r g b a)
                  do (setf (cffi:mem-aref pointer :uint8 (+ x (* y *size*))) value))))))
    (im:save image (pathname path) :format "PNG"))
  (format t "~&wrote ~a~%" path))
