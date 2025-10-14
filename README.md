# PDFium Bundle

Self-contained PDFium distribution builder for static linking with Rust projects.

## Overview

This project creates a fully static PDFium library with no dynamic dependencies, suitable for bundling with Rust applications for distribution.

## Building

```bash
chmod +x build.sh
./build.sh
```

The build process will:
1. Download Google's depot_tools
2. Fetch PDFium source code
3. Configure for static compilation (no dynamic dependencies)
4. Build the static library
5. Create a distribution package in `dist/`

## Output Structure

```
dist/
├── lib/
│   └── libpdfium.a          # Static library
├── include/                 # Header files
│   └── public/
└── pdfium.pc               # pkg-config file
```

## Requirements

- macOS/Linux
- Python 3
- Git
- C++ compiler toolchain
- ~2GB disk space for build

## Usage in Rust

After building, copy the `dist/` directory to your Rust project and configure linking in `build.rs`:

```rust
fn main() {
    println!("cargo:rustc-link-search=native=dist/lib");
    println!("cargo:rustc-link-lib=static=pdfium");
    
    // Required system frameworks on macOS
    #[cfg(target_os = "macos")]
    {
        println!("cargo:rustc-link-lib=framework=ApplicationServices");
        println!("cargo:rustc-link-lib=framework=CoreFoundation");
        println!("cargo:rustc-link-lib=framework=CoreText");
        println!("cargo:rustc-link-lib=framework=Foundation");
        println!("cargo:rustc-link-lib=framework=Security");
    }
    
    // Required C++ standard library
    println!("cargo:rustc-link-lib=stdc++");
}
```

For direct C/C++ compilation, use the link flags from `dist/link_flags.txt`.

## Configuration

The build is configured for maximum compatibility and static linking:
- All dependencies bundled statically
- No V8 JavaScript engine
- No XFA forms support
- Minimal feature set for PDF rendering