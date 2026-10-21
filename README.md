# Image Converter

A macOS application, written in Common Lisp, that converts a folder of images
to another format. Choose an input folder and an output folder, whether to look
in subfolders, and a format; the window lists the images it found, and Convert
fills in each one's status.

Built with SBCL, [objc](https://github.com/lispnik/objc) for AppKit,
[asdf-macos-app](https://github.com/lispnik/asdf-macos-app) for the bundle,
[im](https://github.com/lispnik/im) for reading and writing images, FiveAM for
the tests and ocicl for the dependencies.

![The window after converting a folder to ICO: three files ok, two failed](doc/window.png)

## Using it

- **Input folder** — the images to convert. Choose… opens a folder panel, or
  type a path (`~` works) and press Return.
- **Output folder** — where the converted images go. Choosing an input folder
  first suggests a `Converted` folder inside it. Subfolders of the input are
  recreated here.
- **Include subfolders** — list the images in every folder below the input
  too. An output folder inside the input folder is left out, so converting
  twice does not convert the first run's output.
- **Output format** — every format IM has registered, asked of IM when the
  application starts: HEIF, AVIF, TIFF, JPEG, PNG, GIF, BMP, RAS, ICO, PNM,
  PFM, KRN, LED, SGI, PCX and TGA with the Homebrew build of tecgraf-im.

The list shows each image's path, relative to the input folder, and a status:
blank until it is converted, then **ok** or **error**. **Double-click** a file
to see where it came from, where it went, and the error, or what had to be
changed to fit the format. Convert becomes Stop while it runs. The options are
remembered between launches.

![The details of a file that could not be converted](doc/details.png)

### Fitting an image to a format

Formats store different kinds of image: a GIF must be a palette image, a JPEG
cannot be one, PFM holds only floating-point samples, KRN only grayscale. IM
refuses to write an image in a shape its format does not take, so a plain load
and save fails for about a third of everyday pairs. Each image is therefore
converted to the first shape the format accepts — its own, then without alpha,
then RGB, palette, grayscale and so on — and the details say what was changed:

> Converted from RGB colour (8-bit) to palette colour (8-bit) because GIF
> cannot store the original.

### Nothing is written over

- Two images that would land on one name — `photo.png` and `photo.jpg`, both to
  TIFF — become `photo-png.tif` and `photo-jpg.tif`.
- An output never replaces an input. Converting a folder of PNGs to PNG in
  place writes `photo-png.png`; the status line warns when the output folder
  *is* the input folder.
- Folders are compared after symbolic links are resolved, so `/tmp/x` and
  `/private/tmp/x` are recognised as the same folder.

Existing files in the output folder with the planned names *are* replaced, as
you would expect when converting the same folder again.

## Building

You need SBCL, ocicl, Homebrew's `tecgraf-im` 2.2.1 or later, and a checkout of
[im](https://github.com/lispnik/im), which is not in the ocicl registry. By
default it is looked for beside this directory, at `../im`.

```sh
make deps    # restore the dependencies ocicl.csv pins, into ./ocicl/
make test    # the FiveAM suite
make run     # run from source, unbundled
make app     # build/Image Converter.app
make icon    # draw res/icon.png again
make screenshot INPUT=/a/folder/of/images FORMAT=ICO   # doc/window.png, doc/details.png
```

```sh
make app IM_DIR=~/src/im                 # im from somewhere else
make app OBJC_DIR=~/Projects/common-lisp/objc MACOS_APP_DIR=~/Projects/common-lisp/asdf-macos-app
```

The Makefile runs SBCL without your init file and with a source registry of
this tree (plus `IM_DIR`) alone, so a dependency missing from `ocicl.csv` fails
the build rather than resolving from elsewhere on your machine.

The bundle carries its own copies of IM and everything IM links against
(libtiff, libjpeg, libpng, libheif and its codecs, …) in
`Contents/Frameworks`, so it runs on a Mac without Homebrew. It is signed ad
hoc unless `MACOS_SIGNING_IDENTITY` names a certificate; put that in
`local.mk`, which is not committed.

### Checking the bundle from a script

Nothing can click in a script, so the application has a self test: given a
folder, it converts it as soon as the window is up and quits when done, with
each file's result in `~/Library/Logs/Image Converter.log`.

```sh
open -W --env IMAGE_CONVERTER_SELFTEST=$PWD/samples \
        --env IMAGE_CONVERTER_SELFTEST_FORMAT=HEIF \
        "build/Image Converter.app"
```

The output goes to a new temporary folder (named in the log) unless
`IMAGE_CONVERTER_SELFTEST_OUTPUT` says otherwise. The self test neither reads
nor changes the options remembered from the window.

## Layout

| Path | Contents |
|---|---|
| `src/formats.lisp` | The formats IM can write, as the drop-down shows them |
| `src/scan.lisp` | Finding the images in a folder; canonical paths |
| `src/convert.lisp` | One file into one format, fitting the image to it |
| `src/batch.lisp` | The list of files, where each goes, and how it went |
| `src/macos/` | The window, the menu and `main` |
| `tests/` | FiveAM: formats, scanning, conversion, planning, and the real window driven without clicks |
| `tools/` | The icon, drawn pixel by pixel with IM, and the screenshot tool |

Conversion runs on the main thread, one file per pass of the run loop, so the
window stays responsive, Stop takes effect at the next file, and nothing but
the main thread touches AppKit or IM.

## Notes

- **IM's libraries in the bundle.** `im` reopens its libraries in an image
  restore hook, which runs before asdf-macos-app adds `Contents/Frameworks` to
  CFFI's search path. Left alone, the application loaded Homebrew's copies
  beside the bundled ones, and HEIF and AVIF went missing from the format list.
  `src/macos/frameworks.lisp` installs a restore hook that runs first and
  points `im:*library-path*` at the bundle. Check with
  `vmmap <pid> | grep dylib`: everything IM should come from `Contents/Frameworks`.
- **ICO** holds images up to 255×255 pixels; a larger one is an error that
  says so rather than IM's "invalid or unsupported image data".
- **Alpha.** IM reports that every format can store alpha, then JPEG and PNM
  drop it silently. The written file's header is read back, and the details
  say when the alpha channel was lost.
