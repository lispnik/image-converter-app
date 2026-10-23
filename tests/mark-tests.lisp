;;;; mark-tests.lisp -- the files this application wrote, and leaving them out.

(in-package #:image-converter/tests)

(def-suite mark :in all-tests :description "Marking converted files.")
(in-suite mark)

(test a-mark-names-the-original
  (with-temporary-directory (dir)
    (write-text (path dir "out.png") "")
    (is (null (ic:converted-from (path dir "out.png"))))
    (is-true (ic:mark-converted (path dir "out.png") (path dir "Ünïcode [1].png")))
    (is (string= (path dir "Ünïcode [1].png") (ic:converted-from (path dir "out.png"))))))

(test no-file-no-mark
  (is (null (ic:converted-from "/no/such/file.png")))
  (is-false (ic:mark-converted "/no/such/file.png" "/x.png")))

(test converting-marks-the-output
  (with-temporary-directory (dir)
    (make-sample (path dir "a.png"))
    (let ((entry (first (ic:plan-batch (list (ic:make-entry :input (path dir "a.png")
                                                            :relative "a.png"))
                                       (path dir "out") (format-named "BMP")))))
      (ic:convert-entry entry (format-named "BMP"))
      (is (eq :ok (ic:entry-status entry)))
      (is (string= (path dir "a.png") (ic:converted-from (ic:entry-output entry)))))))

(test a-failed-conversion-marks-nothing
  (with-temporary-directory (dir)
    (write-text (path dir "bad.png") "not an image")
    (let ((entry (first (ic:plan-batch (list (ic:make-entry :input (path dir "bad.png")
                                                            :relative "bad.png"))
                                       (path dir "out") (format-named "BMP")))))
      (ic:convert-entry entry (format-named "BMP"))
      (is (eq :error (ic:entry-status entry)))
      (is (not (file-exists-p (ic:entry-output entry)))))))

(test earlier-conversions-are-left-out-only-beside-their-originals
  (with-temporary-directory (dir)
    (dolist (name '("a.png" "a.jpg" "b.jpg" "plain.png"))
      (write-text (path dir name) ""))
    ;; The app records the original as it was listed: by its canonical path.
    (ic:mark-converted (path dir "a.jpg") (path (ic::canonical-path dir) "a.png"))
    ;; b.jpg's original is not in the folder: converting a folder of earlier
    ;; output on purpose still converts it.
    (ic:mark-converted (path dir "b.jpg") (path (ic::canonical-path dir) "gone" "b.png"))
    (let ((paths (ic:scan-directory dir)))
      (multiple-value-bind (kept skipped) (ic:without-earlier-conversions paths)
        (is (equal '("a.png" "b.jpg" "plain.png") (names kept dir)))
        (is (= 1 skipped))))))
