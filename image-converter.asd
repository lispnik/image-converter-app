;;;; image-converter.asd -- the converter, its window, and their tests.
;;;;
;;;; The bundle is image-converter-app.asd.  It is a file of its own because
;;;; :DEFSYSTEM-DEPENDS-ON is resolved when a .asd is read, and loading the
;;;; converter should not need asdf-macos-app.

(defsystem "image-converter/core"
  :description "Batch conversion of image files with IM; no user interface."
  :author "Matthew Kennedy <burnsidemk@gmail.com>"
  :license "MIT"
  :version "0.1.0"
  :depends-on ("im" "cffi")
  :components ((:module "src"
                :serial t
                :components ((:file "package")
                             (:file "formats")
                             (:file "scan")
                             (:file "convert")
                             (:file "mark")
                             (:file "batch"))))
  :in-order-to ((test-op (test-op "image-converter/tests"))))

(defsystem "image-converter"
  :description "The batch image converter in a Cocoa window."
  :author "Matthew Kennedy <burnsidemk@gmail.com>"
  :license "MIT"
  :version "0.1.0"
  :depends-on ("image-converter/core" "objc" (:require "sb-posix"))
  :components ((:module "src/macos"
                :pathname "src/macos/"
                :serial t
                :components ((:file "frameworks")
                             (:file "window")
                             (:file "app"))))
  :in-order-to ((test-op (test-op "image-converter/tests"))))

(defsystem "image-converter/tests"
  :description "The FiveAM suite."
  :depends-on ("image-converter" "fiveam" (:require "sb-posix"))
  :components ((:module "tests"
                :serial t
                :components ((:file "package")
                             (:file "format-tests")
                             (:file "scan-tests")
                             (:file "convert-tests")
                             (:file "batch-tests")
                             (:file "mark-tests")
                             (:file "leak-tests")
                             (:file "ui-tests"))))
  ;; FIVEAM:RUN! prints failures but returns NIL, and ASDF discards what a
  ;; TEST-OP returns, so the failure has to be an error.
  :perform (test-op (o c)
             (unless (uiop:symbol-call :image-converter/tests :run-tests)
               (error "The test suite failed."))))
