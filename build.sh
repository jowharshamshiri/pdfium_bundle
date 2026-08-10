#!/bin/bash

set -e

# PDFium Bundle Builder
# Creates a self-contained PDFium distribution with no dynamic dependencies

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Build scratch (depot_tools clone + full pdfium source tree + ninja objects —
# ~14 GiB, disposable once `dist/` is produced). Honour the monorepo's central
# build dir when provided: `PDFIUM_BUILD_DIR` wins, else `$BUILD_DIR/pdfium`
# (the dir `dx`/scripts/lib/config.sh exports), else a local `build/` for
# standalone use. This keeps the heavy scratch tree out of the source checkout
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

# Create directories
mkdir -p "${BUILD_DIR}"
mkdir -p "${OUTPUT_DIR}"

# Step 1: Download depot_tools if not present
if [ ! -d "${DEPOT_TOOLS_DIR}" ]; then
    echo "Downloading depot_tools..."
    cd "${BUILD_DIR}"
    git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git
fi

# Add depot_tools to PATH
export PATH="${DEPOT_TOOLS_DIR}:${PATH}"

# Step 2: Download PDFium source if not present
if [ ! -d "${PDFIUM_DIR}" ]; then
    echo "Downloading PDFium source..."
    cd "${BUILD_DIR}"
    gclient config --unmanaged https://pdfium.googlesource.com/pdfium.git
    gclient sync
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
echo "Creating distribution package..."
rm -rf "${OUTPUT_DIR}"/*
mkdir -p "${OUTPUT_DIR}/lib"
mkdir -p "${OUTPUT_DIR}/include"

# Collect all object files and static libraries
echo "Collecting all PDFium object files..."
rm -f "${BUILD_DIR}/pdfium_objects.list" "${BUILD_DIR}/pdfium_libs.list"

# Find all .o files from PDFium components (exclude test files)
# Use word boundaries to avoid excluding files like "bytestring.o" that contain "test"
find out/Release/obj -name "*.o" | grep -v -E "(_test|test_|fuzzer)" > "${BUILD_DIR}/pdfium_objects.list"

# Find pre-built static libraries 
find out/Release/obj -name "*.a" > "${BUILD_DIR}/pdfium_libs.list"

echo "Found $(wc -l < "${BUILD_DIR}/pdfium_objects.list") object files"
echo "Found $(wc -l < "${BUILD_DIR}/pdfium_libs.list") static libraries"

# Create combined static library
echo "Creating combined static library..."

# Convert relative paths to absolute paths and verify files exist
echo "Verifying files exist..."
rm -f "${BUILD_DIR}/verified_objects.list"
while read -r obj; do
    abs_path="${PDFIUM_DIR}/$obj"
    if [ -f "$abs_path" ]; then
        echo "$abs_path" >> "${BUILD_DIR}/verified_objects.list"
    fi
done < "${BUILD_DIR}/pdfium_objects.list"

verified_count=$(wc -l < "${BUILD_DIR}/verified_objects.list" 2>/dev/null || echo "0")
echo "Verified ${verified_count} existing object files"

# Start with verified object files if any exist
if [ -s "${BUILD_DIR}/verified_objects.list" ]; then
    ar rcs "${OUTPUT_DIR}/lib/libpdfium.a" $(cat "${BUILD_DIR}/verified_objects.list")
else
    echo "ERROR: No verified object files found"
    exit 1
fi

echo "Combined static library created: ${OUTPUT_DIR}/lib/libpdfium.a"
echo "Library size: $(ls -lh "${OUTPUT_DIR}/lib/libpdfium.a" | awk '{print $5}')"

# Copy headers (ensure we're in the PDFium directory)
cd "${PDFIUM_DIR}"
cp -r public/ "${OUTPUT_DIR}/include/" || echo "Warning: Headers not copied, may need to run from correct directory"

# Create pkg-config file
cat > "${OUTPUT_DIR}/pdfium.pc" << EOF
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
