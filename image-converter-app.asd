;;;; image-converter-app.asd -- "Image Converter.app", built with asdf-macos-app.
;;;;
;;;;   make app        (or: sbcl --eval '(asdf:make "image-converter-app")' --quit)

(defsystem "image-converter-app"
  :defsystem-depends-on ("asdf-macos-app")
  :class :macos-app-system
  :build-operation "macos-app-op"
  :entry-point "image-converter:main"
  :description "Convert a folder of images to another format, in a Cocoa window."
  :author "Matthew Kennedy <burnsidemk@gmail.com>"
  :license "MIT"
  :version "0.1.0"
  :depends-on ("image-converter")
  :bundle-identifier "org.lispnik.image-converter"
  :bundle-name "Image Converter"
  :bundle-executable "image-converter"
  :bundle-icon "res/icon.png"
  :bundle-principal-class "NSApplication"
  :bundle-category "public.app-category.graphics-design"
  :bundle-copyright "MIT"
  :bundle-log t
  ;; The folders chosen are often in one of these, and macOS wants a reason to
  ;; show the first time each is read.
  :bundle-info-plist
  (("NSDocumentsFolderUsageDescription"
    . "Image Converter reads and writes images in the folders you choose.")
   ("NSDesktopFolderUsageDescription"
    . "Image Converter reads and writes images in the folders you choose.")
   ("NSDownloadsFolderUsageDescription"
    . "Image Converter reads and writes images in the folders you choose.")
   ("NSRemovableVolumesUsageDescription"
    . "Image Converter reads and writes images in the folders you choose."))
  ;; Merged against this file rather than the current directory, which is what
  ;; a bare "build/" would resolve against.
  :bundle-output-directory
  #.(merge-pathnames "build/"
                     (uiop:pathname-directory-pathname
                      (or *load-truename* *default-pathname-defaults*)))
  ;; Ad hoc unless told otherwise; an empty variable counts as unset.
  :code-signing-identity #.(let ((identity (uiop:getenv "MACOS_SIGNING_IDENTITY")))
                             (if (and identity (plusp (length identity)))
                                 identity
                                 "-")))
