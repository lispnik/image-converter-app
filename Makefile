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
#   make release-check   refuse a bundle that cannot be shipped
#   make notarize        notarise the bundle and staple the ticket
#   make dmg             a signed disk image of the notarised bundle, in dist/
#   make notarize-dmg    notarise the disk image and staple it
#   make release         all four
#
# im is not in the ocicl registry, so it comes from a checkout: IM_DIR, by
# default the one beside this directory.  The IM shared libraries themselves
# come from Homebrew's tecgraf-im (brew install lispnik/tap/tecgraf-im), and
# the bundle carries copies of them.

SBCL ?= sbcl

# Signing, which is personal: local.mk, never committed.  It sets
#   MACOS_SIGNING_IDENTITY = Developer ID Application: Your Name (TEAMID)
#   NOTARY_PROFILE = a profile stored with `xcrun notarytool store-credentials'
-include local.mk
# image-converter-app.asd reads the identity from the environment.
export MACOS_SIGNING_IDENTITY
NOTARY_PROFILE ?=

APP = build/Image Converter.app
VERSION = $(shell sed -n 's/.*:version "\(.*\)".*/\1/p' image-converter-app.asd | head -1)
DIST = dist
DMG = $(DIST)/Image-Converter-$(VERSION).dmg

IM_DIR ?= ../im
# Sibling checkouts that shadow the pinned objc and asdf-macos-app.
OBJC_DIR ?=
# The bundle needs an asdf-macos-app that puts Contents/Frameworks on CFFI's
# search path before im's restore hook reopens its libraries; the release
# ocicl.csv pins does it later, and IM loads from Homebrew.  Until a release
# with that is pinned, the checkout beside this one; MACOS_APP_DIR= for the pin.
MACOS_APP_DIR ?= ../asdf-macos-app

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

.PHONY: deps test run app icon screenshot clean \
        release-check notarize dmg notarize-dmg release

deps:
	ocicl install

# MallocScribble=1 fills each new heap block with 0xAA, which is what lets
# tests/leak-tests.lisp see a byte IM wrote without setting it.
test:
	MallocScribble=1 $(LISP) --eval '(asdf:load-system "image-converter/tests")' \
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

# What Apple would refuse, or what would notarise and then not open on
# another Mac: an ad hoc signature, and a runtime that links anything outside
# the system.  Homebrew's SBCL links Homebrew's libzstd, for core compression;
# build with one configured --without-sb-core-compression.
release-check:
	@test -d "$(APP)" || { echo "error: no $(APP); make app first" >&2; exit 1; }
	@codesign -dvv "$(APP)" 2>&1 | grep -q "Authority=Developer ID Application" || { \
	  echo "error: $(APP) is not signed with a Developer ID Application identity." >&2; \
	  echo "  set MACOS_SIGNING_IDENTITY in local.mk and make app again" >&2; \
	  exit 1; }
	@for f in "$(APP)"/Contents/MacOS/image-converter "$(APP)"/Contents/Frameworks/*.dylib; do \
	  otool -L "$$f" | tail -n +2 \
	    | grep -vE "@loader_path|@executable_path|@rpath|/usr/lib/|/System/" \
	    | sed "s|^|$$f:|"; \
	done | grep . && { \
	  echo "error: the bundle links libraries from outside it (above)." >&2; \
	  exit 1; } || true
	codesign --verify --deep --strict "$(APP)"
	@echo "$(APP) $(VERSION) can be shipped"

notarize: release-check
	@test -n "$(NOTARY_PROFILE)" || { \
	  echo "error: set NOTARY_PROFILE in local.mk" >&2; exit 1; }
	$(LISP) --eval '(asdf:load-system "asdf-macos-app")' \
	        --eval '(macos-app:notarize "$(APP)" :keychain-profile "$(NOTARY_PROFILE)")'
	spctl -a -vvv -t exec "$(APP)"

# The app and a link to /Applications, which every Mac user knows what to do
# with.  Made from the bundle as it stands, so after notarize.
dmg:
	@xcrun stapler validate "$(APP)" > /dev/null || { \
	  echo "error: $(APP) has no notarisation ticket; make notarize first" >&2; exit 1; }
	rm -rf "$(DIST)/stage" "$(DMG)"
	mkdir -p "$(DIST)/stage"
	ditto "$(APP)" "$(DIST)/stage/Image Converter.app"
	ln -s /Applications "$(DIST)/stage/Applications"
	hdiutil create -volname "Image Converter $(VERSION)" -srcfolder "$(DIST)/stage" \
	        -ov -format UDZO "$(DMG)"
	rm -rf "$(DIST)/stage"
	codesign --force --sign "$(MACOS_SIGNING_IDENTITY)" --timestamp "$(DMG)"
	@echo "built $(DMG)"

notarize-dmg:
	@test -n "$(NOTARY_PROFILE)" || { \
	  echo "error: set NOTARY_PROFILE in local.mk" >&2; exit 1; }
	xcrun notarytool submit "$(DMG)" --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple "$(DMG)"
	spctl -a -vvv -t open --context context:primary-signature "$(DMG)"

release: notarize dmg notarize-dmg

clean:
	rm -rf build dist
	find . -name '*.fasl' -not -path './ocicl/*' -delete
