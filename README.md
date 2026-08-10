# pdfium-bundle

A build recipe that produces a fully static [PDFium](https://pdfium.googlesource.com/)
library, so a program can render and manipulate PDFs without requiring PDFium to
be installed — or shipped as a loose shared object beside the executable.

**This project is packaging, not authorship.** PDFium is the PDF library
developed by Google for the Chromium project, and everything this repository
distributes was written by those authors. What is original here is a build
script. Credit belongs upstream; bug reports about PDF rendering belong at
[the PDFium project](https://pdfium.googlesource.com/pdfium/), not here.

## Why this exists

PDFium is excellent and awkward to consume. It is built with Chromium's
toolchain — `depot_tools`, `gclient`, `gn`, `ninja` — which is a large,
opinionated apparatus to stand up if all you want is a `.a` file. The usual
alternatives each have a cost:

- **Ship `pdfium.dll` / `libpdfium.so` beside the binary.** Now you have a
  loose file to sign, notarise, install, and keep in step with the executable —
  and a program that fails at runtime rather than at build time when it goes
  missing.
- **Use a prebuilt from a third party.** Now you are trusting a binary whose
  build configuration you cannot see, at a revision you do not control.
- **Build it yourself, in every project.** Now every project carries the
  Chromium toolchain and a long compile.

This repository does that build once, with the recipe committed and readable,
and emits a plain static library plus headers and a `pkg-config` file. Consumers
link it like any other C library and get a single self-contained executable.

Nothing here is specific to any particular application.

## Building

```bash
./build.sh          # Linux, macOS
./build.ps1         # Windows
```

The script clones `depot_tools`, fetches the PDFium source, configures a release
build with no dynamic dependencies, and builds it. The scratch tree is large —
depot_tools, the full PDFium source, and the ninja objects come to roughly
14 GiB — so it is kept outside this repository. Set `PDFIUM_BUILD_DIR` to choose
where it goes; otherwise it lands under `$BUILD_DIR/pdfium`.

The output in `dist/` is small, around 25 MiB:

```
dist/include/    PDFium's public headers
dist/lib/        the static library
dist/pdfium.pc   pkg-config metadata, so consumers can find both
```

## Using it

Point `pkg-config` at `dist/` and link normally:

```bash
PKG_CONFIG_PATH=/path/to/pdfium-bundle/dist pkg-config --cflags --libs pdfium
```

From Rust, a `build.rs` that reads the same `.pc` file gets the include path and
link flags without hardcoding anything. PDFium is C++, so a consumer links a C++
standard library too — `pdfium.pc` records which one the build expects.

## Licensing — please read this before distributing anything

PDFium is BSD 3-Clause, which is permissive but not free of obligations: a
binary redistribution must reproduce the copyright notice, the conditions, and
the disclaimer in your documentation or other materials.

More importantly, **PDFium is not a single-licence work.** Its tree pulls in
third-party libraries — FreeType, libjpeg-turbo, libopenjpeg, libpng, zlib,
Skia, Abseil and others — each under its own terms, several with their own
attribution requirements. A static library built from PDFium contains all of
them.

`LICENSE` in this repository carries PDFium's own notice and explains the rest.
Because this repository builds from an upstream checkout rather than vendoring
it, the authoritative list of what actually went into your binary is the
`LICENSE` file and `third_party/` directory of the checkout your build produced.
Generate any product notice file from that, not from here.

This is a pointer, not legal advice.
