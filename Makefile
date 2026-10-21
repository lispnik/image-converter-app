# Image Converter.
#
#   make deps    restore the dependencies ocicl.csv pins, into ./ocicl/
#   make test    run the FiveAM suite
#   make run     run the application from source, unbundled
#   make app     build "build/Image Converter.app"
#   make icon    draw res/icon.png again, from tools/icon.lisp
#   make screenshot INPUT=folder   draw the window into doc/, converting FOLDER
#   make clean   remove the bundle and the fasls
#
# im is not in the ocicl registry, so it comes from a checkout: IM_DIR, by
# default the one beside this directory.  The IM shared libraries themselves
# come from Homebrew's tecgraf-im (brew install lispnik/tap/tecgraf-im), and
# the bundle carries copies of them.

SBCL ?= sbcl

# Signing, which is personal: local.mk, never committed.
-include local.mk

IM_DIR ?= ../im
# Optional sibling checkouts that shadow the pinned objc and asdf-macos-app.
OBJC_DIR ?=
MACOS_APP_DIR ?=

# :IGNORE-INHERITED-CONFIGURATION so that a dependency missing from ocicl.csv
# fails here, rather than resolving to whatever the developer's own source
# registry happens to reach.  IM_DIR is a :DIRECTORY, not a :TREE: the checkout
# has an ocicl/ of its own, whose copies must not shadow the ones pinned here.
REGISTRY = (asdf:initialize-source-registry \
              (list :source-registry \
                    (list :directory (truename "$(IM_DIR)/")) \
                    $(if $(OBJC_DIR),(list :tree (truename "$(OBJC_DIR)/"))) \
                    $(if $(MACOS_APP_DIR),(list :tree (truename "$(MACOS_APP_DIR)/"))) \
                    (list :tree (truename "./")) \
                    :ignore-inherited-configuration))

LISP = $(SBCL) --non-interactive --no-userinit --no-sysinit \
         --eval '(require :asdf)' --eval '$(REGISTRY)'

.PHONY: deps test run app icon screenshot clean

deps:
	ocicl install

test:
	$(LISP) --eval '(asdf:load-system "image-converter/tests")' \
	        --eval '(uiop:quit (if (image-converter/tests:run-tests) 0 1))'

run:
	$(LISP) --eval '(asdf:load-system "image-converter")' \
	        --eval '(image-converter:main)'

app:
	$(LISP) --eval '(asdf:make "image-converter-app")'

icon:
	$(LISP) --eval '(asdf:load-system "im")' \
	        --load tools/icon.lisp \
	        --eval '(image-converter-icon:main)'

screenshot:
	INPUT="$(INPUT)" FORMAT="$(FORMAT)" $(LISP) --eval '(asdf:load-system "image-converter")' \
	        --load tools/screenshot.lisp \
	        --eval '(image-converter-screenshot:main)'

clean:
	rm -rf build
	find . -name '*.fasl' -not -path './ocicl/*' -delete
