<#
PDFium Bundle Builder (Windows / Windows PowerShell 5.1)

Windows port of build.sh. Produces a self-contained static PDFium library for
MSVC/Rust linking, into a BUILD directory:

    <dist>\lib\pdfium.lib     MSVC static library (rustc-link-lib=static=pdfium)
    <dist>\include\public\    PDFium public C headers

<dist> is $env:PDFIUM_BUNDLE_DIST_DIR when set, else "dist" under the build
directory. The product is never written into this source tree and never copied
into a consumer's: consumers are told where it is via PDFIUM_BUNDLE_DIST_DIR.
Copying it into the consuming crate is what made both repositories
un-buildable from a fresh clone — the copy was gitignored, so the crate
expected a directory that existed only on the machine that ran this script.

It mirrors the macOS/Linux build.sh flow:
    depot_tools -> gclient sync pdfium -> gn gen (static) -> ninja -> archive.

Where it MUST differ from build.sh (platform reality, not preference):
  - MSVC emits .obj (not .o); the archiver is lib.exe (not ar); the static
    link name is pdfium.lib (not libpdfium.a).
  - depot_tools must use the locally installed Visual Studio, selected with
    DEPOT_TOOLS_WIN_TOOLCHAIN=0.
  - We ask gn for a single complete static lib (pdf_is_complete_lib=true). If
    that artifact is not produced we fall back to combining every non-test
    .obj with lib.exe, exactly as build.sh combines .o files with ar.

Prerequisites:
  - Visual Studio 2022 with "Desktop development with C++" + a Windows 10/11
    SDK (the Chromium toolchain needs cl.exe/lib.exe and the SDK debuggers).
  - Git on PATH.
  - ~15 GB free disk; a SHORT checkout path (Chromium source blows past
    MAX_PATH - prefer something like C:\src\pdfium_bundle).

Compatible with Windows PowerShell 5.1 (powershell.exe). Pure ASCII only.
#>

$ErrorActionPreference = "Stop"

# --- paths (mirror build.sh) ---------------------------------------------
$ScriptDir     = Split-Path -Parent $MyInvocation.MyCommand.Path
$BuildDir      = if ($env:PDFIUM_BUILD_DIR) { $env:PDFIUM_BUILD_DIR }
                 elseif ($env:BUILD_DIR) { Join-Path $env:BUILD_DIR "pdfium" }
                 else { Join-Path $ScriptDir "build" }
$DepotToolsDir = Join-Path $BuildDir "depot_tools"
$PdfiumDir     = Join-Path $BuildDir "pdfium"
$OutputDir     = if ($env:PDFIUM_BUNDLE_DIST_DIR) { $env:PDFIUM_BUNDLE_DIST_DIR }
                 else { Join-Path $BuildDir "dist" }
$OutRelease    = "out/Release"   # gn/ninja use forward slashes; this is relative to $PdfiumDir

Write-Host "=== PDFium Bundle Builder (Windows) ==="
Write-Host "Build directory:  $BuildDir"
Write-Host "Output directory: $OutputDir"

# --- helper: run a native command and stop on a non-zero exit code -------
function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$File,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory
    )
    if ($WorkingDirectory) { Push-Location $WorkingDirectory }
    try {
        & $File @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "Command failed (exit $LASTEXITCODE): $File $($Arguments -join ' ')"
        }
    }
    finally {
        if ($WorkingDirectory) { Pop-Location }
    }
}

# --- locate Visual Studio's lib.exe (for the object-combine fallback) ----
function Get-MsvcLibExe {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path -LiteralPath $vswhere)) {
        throw "vswhere.exe not found - install Visual Studio 2022 with the C++ workload."
    }
    $installPath = & $vswhere -latest -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath
    if ([string]::IsNullOrWhiteSpace($installPath)) {
        throw "No Visual Studio install with the VC x64 toolset was found."
    }
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }
    $lib = Get-ChildItem -Path (Join-Path $installPath "VC\Tools\MSVC") -Recurse `
        -Filter "lib.exe" -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match "Hostx64\\$arch\\lib.exe$" -or $_.FullName -match "Hostx64\\x64\\lib.exe$" } |
        Select-Object -First 1
    if (-not $lib) { throw "lib.exe not found under the VC toolset at $installPath." }
    return $lib.FullName
}

# Create working + output roots.
New-Item -ItemType Directory -Path $BuildDir  -Force | Out-Null
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

# --- Windows toolchain env for depot_tools -------------------------------
# 0 = use the locally installed Visual Studio rather than Google's internal
# toolchain package. depot_tools must be FIRST on PATH so its python/git
# shims win.
$env:DEPOT_TOOLS_WIN_TOOLCHAIN = "0"
$env:DEPOT_TOOLS_UPDATE        = "1"
$env:GYP_MSVS_VERSION          = "2022"
$env:PATH                      = "$DepotToolsDir;$env:PATH"

# Chromium's setup_toolchain.py validates that every path in LIB/INCLUDE/LIBPATH
# exists and aborts on a stray entry. depot_tools sets these up itself from the
# installed SDK via vcvars, so clear any inherited MSVC env (e.g. a leftover
# user-level LIB pointing at a non-existent dir) before gn runs.
$env:LIB     = $null
$env:INCLUDE = $null
$env:LIBPATH = $null
Remove-Item Env:CL   -ErrorAction SilentlyContinue
Remove-Item Env:_CL_ -ErrorAction SilentlyContinue

# --- Step 1: depot_tools --------------------------------------------------
if (-not (Test-Path -LiteralPath $DepotToolsDir)) {
    Write-Host "Downloading depot_tools..."
    Invoke-Native -File "git" -WorkingDirectory $BuildDir -Arguments @(
        "clone", "https://chromium.googlesource.com/chromium/tools/depot_tools.git"
    )
}

$gclient = Join-Path $DepotToolsDir "gclient.bat"
$gn      = Join-Path $DepotToolsDir "gn.bat"
$ninja   = Join-Path $DepotToolsDir "ninja.bat"

# First gclient run bootstraps depot_tools' bundled Python/git on Windows.
Write-Host "Bootstrapping depot_tools (first run may take a while)..."
& $gclient | Out-Null  # may return non-zero while only printing help; that is fine

# --- Step 2: fetch PDFium source -----------------------------------------
if (-not (Test-Path -LiteralPath $PdfiumDir)) {
    Write-Host "Downloading PDFium source (gclient sync, multi-GB)..."
    Invoke-Native -File $gclient -WorkingDirectory $BuildDir -Arguments @(
        "config", "--unmanaged", "https://pdfium.googlesource.com/pdfium.git"
    )
    Invoke-Native -File $gclient -WorkingDirectory $BuildDir -Arguments @("sync")
}

if (-not (Test-Path -LiteralPath $PdfiumDir)) {
    throw "PDFium source directory not found after gclient sync: $PdfiumDir"
}

# --- Step 3: configure the static build ----------------------------------
# Same feature set as build.sh (no Skia / XFA / V8, everything bundled
# static), plus pdf_is_complete_lib=true so ninja can emit ONE static lib.
# All-boolean args => no embedded quotes to escape through PowerShell.
Write-Host "Configuring build for static linking..."
$gnArgs = @(
    "is_debug=false"
    "pdf_use_skia=false"
    "pdf_enable_xfa=false"
    "pdf_enable_v8=false"
    "pdf_is_standalone=true"
    "is_component_build=false"
    "pdf_is_complete_lib=true"
    "use_custom_libcxx=false"
    "treat_warnings_as_errors=false"
    "pdf_bundle_freetype=true"
    "use_system_freetype=false"
    "use_system_libpng=false"
    "use_system_zlib=false"
    "use_system_libjpeg=false"
) -join " "
# If gn rejects an arg (PDFium occasionally drops one), remove it from the
# list above and re-run; the message names the offending arg.
Invoke-Native -File $gn -WorkingDirectory $PdfiumDir -Arguments @("gen", $OutRelease, "--args=$gnArgs")

# --- Step 4: build --------------------------------------------------------
Write-Host "Building PDFium (ninja)..."
Invoke-Native -File $ninja -WorkingDirectory $PdfiumDir -Arguments @("-C", $OutRelease, "pdfium")

# --- Step 5: assemble the distribution -----------------------------------
Write-Host "Creating distribution package..."
if (Test-Path -LiteralPath $OutputDir) { Remove-Item -LiteralPath $OutputDir -Recurse -Force }
$libDir = Join-Path $OutputDir "lib"
$incDir = Join-Path $OutputDir "include"
New-Item -ItemType Directory -Path $libDir -Force | Out-Null
New-Item -ItemType Directory -Path $incDir -Force | Out-Null

$libOut     = Join-Path $libDir "pdfium.lib"
$objRoot    = Join-Path $PdfiumDir "out\Release\obj"

# Prefer the single complete static library produced by pdf_is_complete_lib.
# Match the real static lib named exactly "pdfium.lib" - NOT the shared
# library's import stub "pdfium.dll.lib".
$completeLib = Get-ChildItem -Path (Join-Path $PdfiumDir "out\Release") -Recurse `
    -Filter "pdfium.lib" -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -eq "pdfium.lib" } |
    Sort-Object Length -Descending | Select-Object -First 1

if ($completeLib -and $completeLib.Length -gt 1MB) {
    Write-Host "Using complete static library: $($completeLib.FullName) ($([math]::Round($completeLib.Length/1MB)) MB)"
    Copy-Item -LiteralPath $completeLib.FullName -Destination $libOut -Force
}
else {
    # Fallback: combine every non-test .obj with lib.exe, mirroring build.sh's
    # `ar rcs libpdfium.a $(verified .o files)`.
    Write-Host "Complete lib not found; combining object files with lib.exe..."
    if (-not (Test-Path -LiteralPath $objRoot)) {
        throw "Object directory not found: $objRoot (did ninja build succeed?)"
    }
    $objs = Get-ChildItem -Path $objRoot -Recurse -Filter "*.obj" -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch "(_test|test_|fuzzer)" } |
        ForEach-Object { $_.FullName }
    Write-Host "Found $($objs.Count) object files"
    if ($objs.Count -eq 0) { throw "No object files found under $objRoot" }

    # lib.exe can take far more files than the command line allows; pass them
    # via a response file, one quoted absolute path per line.
    $rsp = Join-Path $BuildDir "pdfium_objects.rsp"
    $rspLines = $objs | ForEach-Object { '"' + $_ + '"' }
    [System.IO.File]::WriteAllLines($rsp, $rspLines, (New-Object System.Text.ASCIIEncoding))

    $libExe = Get-MsvcLibExe
    # Put the toolset bin dir on PATH so lib.exe resolves its sibling DLLs.
    $env:PATH = (Split-Path -Parent $libExe) + ";$env:PATH"
    Invoke-Native -File $libExe -Arguments @("/NOLOGO", "/OUT:$libOut", "@$rsp")
}

if (-not (Test-Path -LiteralPath $libOut)) { throw "Static library was not produced: $libOut" }
$libMB = [math]::Round((Get-Item -LiteralPath $libOut).Length / 1MB, 1)
Write-Host "Static library: $libOut ($libMB MB)"

# Copy the public headers: dist\include\public\ (build.sh: cp -r public/ include/).
$publicSrc = Join-Path $PdfiumDir "public"
if (-not (Test-Path -LiteralPath $publicSrc)) { throw "PDFium public headers not found: $publicSrc" }
Copy-Item -LiteralPath $publicSrc -Destination $incDir -Recurse -Force

# --- Step 6: stage into the bundled Rust crate ---------------------------
Write-Host "=== Build Complete ==="
Write-Host "PDFium static library: $libOut"
Write-Host "Headers:               $incDir\public"
Write-Host ""
Write-Host "To use it, point the consuming crate at this directory:"
Write-Host ""
Write-Host "    PDFIUM_BUNDLE_DIST_DIR=$OutputDir"
Write-Host ""
Write-Host "Nothing is copied anywhere; the consuming crate reads that variable."
