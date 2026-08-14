#!/bin/bash

set -euo pipefail

# PDFium Bundle Builder
# Creates a self-contained PDFium distribution with no dynamic dependencies

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Build scratch (depot_tools clone + full pdfium source tree + ninja objects —
# ~14 GiB, disposable once `dist/` is produced). Honour the monorepo's central
# build dir when provided: `PDFIUM_BUILD_DIR` wins, else `$BUILD_DIR/pdfium`
# (the central build directory a monorepo's own tooling exports), else a
# local `build/` for standalone use. This keeps the heavy scratch tree out of the source checkout
# and alongside the other build artifacts under machinefabric/build/.
BUILD_DIR="${PDFIUM_BUILD_DIR:-${BUILD_DIR:+${BUILD_DIR}/pdfium}}"
BUILD_DIR="${BUILD_DIR:-${SCRIPT_DIR}/build}"
DEPOT_TOOLS_DIR="${BUILD_DIR}/depot_tools"
PDFIUM_DIR="${BUILD_DIR}/pdfium"
# The static lib + headers are a build PRODUCT and go with the rest of the
# build output — never into this source tree, and never copied into a consumer's
# tree. Consumers are TOLD where it is (pdfium-render-bundled reads
# PDFIUM_BUNDLE_DIST_DIR), which is the only arrangement in which a fresh clone
# of either repository builds without someone remembering to copy a directory.
OUTPUT_DIR="${PDFIUM_BUNDLE_DIST_DIR:-${BUILD_DIR}/dist}"

echo "=== PDFium Bundle Builder ==="
echo "Build directory: ${BUILD_DIR}"
echo "Output directory: ${OUTPUT_DIR}"

# Every step below is guarded on evidence that it FINISHED, never on a
# directory existing. The two are not the same, and treating them as the same
# is what made this script fragile: a clone or a sync killed part way — a lost
# network, a full disk, a closed laptop — left the directory behind, so every
# later run skipped the step and failed somewhere further down, forever. The
# fetches here take tens of minutes and pull ~14 GiB, so being interrupted is
# the normal case and not the exotic one.

mkdir -p "${BUILD_DIR}"

# Step 1: depot_tools.
#
# Guarded on the tool this needs, not on the directory holding it. A partial
# clone is a directory with no `gclient` in it, and is replaced rather than
# trusted. The clone lands under a scratch name and is renamed into place, so
# the guarded path only ever appears complete.
if [ ! -x "${DEPOT_TOOLS_DIR}/gclient" ]; then
    if [ -d "${DEPOT_TOOLS_DIR}" ]; then
        echo "depot_tools is present but has no gclient — discarding a partial clone"
        rm -rf "${DEPOT_TOOLS_DIR}"
    fi
    echo "Downloading depot_tools..."
    rm -rf "${DEPOT_TOOLS_DIR}.partial"
    git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git \
        "${DEPOT_TOOLS_DIR}.partial"
    mv "${DEPOT_TOOLS_DIR}.partial" "${DEPOT_TOOLS_DIR}"
fi

# Add depot_tools to PATH
export PATH="${DEPOT_TOOLS_DIR}:${PATH}"

# Step 2: the PDFium source tree.
#
# `gclient sync` IS the resync — it is incremental and idempotent, and running
# it on a half-fetched tree is precisely how that tree gets finished. So the
# stamp is written by us after sync returns 0, and its absence means "sync",
# not "the directory is missing". Set RESYNC=1 to force one.
SYNCED_STAMP="${BUILD_DIR}/.pdfium-synced"
if [ ! -f "${SYNCED_STAMP}" ] || [ "${RESYNC:-0}" = "1" ]; then
    rm -f "${SYNCED_STAMP}"
    cd "${BUILD_DIR}"
    # The gclient config file is written once; rewriting it on every run would
    # discard any local customisation for no gain.
    if [ ! -f "${BUILD_DIR}/.gclient" ]; then
        echo "Configuring gclient for PDFium..."
        gclient config --unmanaged https://pdfium.googlesource.com/pdfium.git
    fi
    echo "Syncing PDFium source (multi-GB on a first run)..."
    gclient sync
    if [ ! -d "${PDFIUM_DIR}" ]; then
        echo "ERROR: gclient sync reported success but ${PDFIUM_DIR} does not exist." >&2
        exit 1
    fi
    touch "${SYNCED_STAMP}"
fi

cd "${PDFIUM_DIR}"

# Step 3: Generate build files with static linking configuration
echo "Configuring build for static linking..."
gn gen out/Release --args='
    is_debug=false
    pdf_use_skia=false
    pdf_use_skia_paths=false
    pdf_enable_xfa=false
    pdf_enable_v8=false
    pdf_is_standalone=true
    is_component_build=false
    use_custom_libcxx=false
    use_sysroot=false
    treat_warnings_as_errors=false
    pdf_bundle_freetype=true
    use_system_freetype=false
    use_system_libpng=false
    use_system_zlib=false
    use_system_libjpeg=false
'

# Step 4: Build PDFium
echo "Building PDFium..."
ninja -C out/Release pdfium

# Step 5: Create distribution package
#
# Assembled under a staging name and PUBLISHED by rename. Populating
# ${OUTPUT_DIR} in place meant that an interrupted run left a directory that
# looked like a distribution and was not — a truncated libpdfium.a, or headers
# that never arrived — and the consumer linked against it and failed with an
# error about a symbol rather than about a half-built bundle.
echo "Creating distribution package..."
STAGING_DIR="${OUTPUT_DIR}.staging"
rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}/lib"
mkdir -p "${STAGING_DIR}/include"

# Collect all object files and static libraries
echo "Collecting all PDFium object files..."
rm -f "${BUILD_DIR}/pdfium_objects.list" "${BUILD_DIR}/pdfium_libs.list" \
      "${BUILD_DIR}/pdfium_all_objects.list"

# Find all .o files from PDFium components (exclude test files)
# Use word boundaries to avoid excluding files like "bytestring.o" that contain "test"
#
# The two commands are separated because `pipefail` is on and a `grep` that
# matches nothing exits 1 — a legitimate outcome here, and one that the
# "no verified object files" check below reports far better than an abrupt
# exit would. `grep` exiting 2 is a real error and still stops the build.
find out/Release/obj -name "*.o" > "${BUILD_DIR}/pdfium_all_objects.list"
grep -v -E "(_test|test_|fuzzer)" "${BUILD_DIR}/pdfium_all_objects.list" \
    > "${BUILD_DIR}/pdfium_objects.list" || [ $? -eq 1 ]

# Find pre-built static libraries 
find out/Release/obj -name "*.a" > "${BUILD_DIR}/pdfium_libs.list"

echo "Found $(wc -l < "${BUILD_DIR}/pdfium_objects.list") object files"
echo "Found $(wc -l < "${BUILD_DIR}/pdfium_libs.list") static libraries"

# Create combined static library
echo "Creating combined static library..."

# Convert relative paths to absolute paths.
#
# The list came from `find` moments ago, so a name on it that is not a file is
# a tree changing underneath the build — a concurrent ninja, or a clear that
# ran mid-build. That used to be dropped silently, which produced an archive
# missing whatever had gone and a link error naming a symbol instead of the
# cause. It is reported and it stops.
echo "Verifying files exist..."
rm -f "${BUILD_DIR}/verified_objects.list"
while read -r obj; do
    abs_path="${PDFIUM_DIR}/$obj"
    if [ ! -f "$abs_path" ]; then
        echo "ERROR: ${abs_path} was listed by find and is now gone." >&2
        echo "Something is writing to the build tree while this runs. Re-run this script." >&2
        exit 1
    fi
    echo "$abs_path" >> "${BUILD_DIR}/verified_objects.list"
done < "${BUILD_DIR}/pdfium_objects.list"

verified_count=$(wc -l < "${BUILD_DIR}/verified_objects.list" 2>/dev/null || echo "0")
echo "Verified ${verified_count} existing object files"

if [ ! -s "${BUILD_DIR}/verified_objects.list" ]; then
    echo "ERROR: No object files found under out/Release/obj — nothing was built." >&2
    exit 1
fi
ar rcs "${STAGING_DIR}/lib/libpdfium.a" $(cat "${BUILD_DIR}/verified_objects.list")

echo "Combined static library created: ${STAGING_DIR}/lib/libpdfium.a"
echo "Library size: $(ls -lh "${STAGING_DIR}/lib/libpdfium.a" | awk '{print $5}')"

# Copy headers. A distribution without them is unusable, so a failure here
# fails the build rather than printing a warning nobody reads and publishing
# an incomplete bundle anyway.
cd "${PDFIUM_DIR}"
cp -r public/ "${STAGING_DIR}/include/"
if [ ! -f "${STAGING_DIR}/include/public/fpdfview.h" ]; then
    echo "ERROR: headers were copied but ${STAGING_DIR}/include/public/fpdfview.h is missing." >&2
    exit 1
fi

# Create pkg-config file. It names the PUBLISHED directory, not the staging
# one — it is read after the rename below and must point where the files
# actually end up.
cat > "${STAGING_DIR}/pdfium.pc" << EOF
prefix=${OUTPUT_DIR}
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: PDFium
Description: PDFium PDF library (static)
Version: $(git rev-parse --short HEAD)
Libs: -L\${libdir} -lpdfium
Cflags: -I\${includedir}
EOF

# Publish: two renames, so ${OUTPUT_DIR} goes from the previous complete
# distribution straight to this one and is never observed half-populated.
mkdir -p "$(dirname "${OUTPUT_DIR}")"
rm -rf "${OUTPUT_DIR}.previous"
if [ -d "${OUTPUT_DIR}" ]; then
    mv "${OUTPUT_DIR}" "${OUTPUT_DIR}.previous"
fi
mv "${STAGING_DIR}" "${OUTPUT_DIR}"
rm -rf "${OUTPUT_DIR}.previous"

echo "=== Build Complete ==="
echo "PDFium static library: ${OUTPUT_DIR}/lib/libpdfium.a"
echo "Headers: ${OUTPUT_DIR}/include/"
echo "pkg-config: ${OUTPUT_DIR}/pdfium.pc"
echo ""
echo "To use it, point the consuming crate at this directory:"
echo ""
echo "    PDFIUM_BUNDLE_DIST_DIR=${OUTPUT_DIR}"
echo ""
echo "Nothing is copied anywhere. Copying the product into a consumer's source"
echo "tree is what made both repositories un-buildable from a fresh clone: the"
echo "copy was gitignored, so the crate expected a directory that only existed"
echo "on the machine that had run this script."
