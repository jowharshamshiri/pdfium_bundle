#!/bin/bash
#
# The guards in build.sh, exercised against stubbed tools.
#
# A real run of build.sh clones depot_tools, syncs ~14 GiB of Chromium and
# compiles for tens of minutes, so nothing here calls the real thing. What is
# under test is not pdfium — it is the script's decisions about what has
# already been done, and those are exactly the decisions that were wrong. Every
# case below reproduces a way a real run was interrupted and asserts that the
# next run converges instead of failing forever.
#
# TEST9700-9704.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASSED=0
FAILED=0

# Each case below runs in a subshell, so a counter it increments dies with it.
# The subshell's EXIT STATUS is the result, and `case_result` in the parent is
# what counts — which is why `fail` stops the case rather than noting it.
fail() {
    echo "  FAIL: $*" >&2
    # The build's own output, when there is one to show. Every call site that
    # wanted this wrote `fail "..."; tail -20 "$out" >&2` — and `fail` exits,
    # so the tail never ran and every failure reported a headline with nothing
    # under it. Two separate causes were debugged by hand before anyone
    # noticed the harness had been silent all along.
    if [ -n "${FAIL_OUTPUT:-}" ] && [ -s "${FAIL_OUTPUT}" ]; then
        sed 's/^/    | /' "${FAIL_OUTPUT}" | tail -20 >&2
    fi
    exit 1
}

case_result() {
    if [ "$1" -eq 0 ]; then
        echo "  ok   — $2"
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
    fi
}

# A directory of stub executables standing in for depot_tools and the
# toolchain. Each records that it ran, so a test can assert a step happened
# rather than inferring it from a side effect it shares with other steps.
make_stubs() {
    local bin="$1" log="$2"
    mkdir -p "$bin"

    # `sync --revision pdfium@<sha>` records the sha it was asked for, so the
    # stub `git rev-parse` below can answer with it. The script verifies that
    # the checkout is at the pinned revision, and a stub that always answered
    # the same thing would either fail every case or pass one that a real
    # mismatch would fail.
    cat > "$bin/gclient" <<EOF
#!/bin/bash
echo "gclient \$*" >> "$log"
case "\$1" in
    config) : > .gclient ;;
    sync)
        mkdir -p pdfium
        for arg in "\$@"; do
            case "\$arg" in
                pdfium@*) printf '%s' "\${arg#pdfium@}" > pdfium/.stub-revision ;;
            esac
        done
        ;;
esac
exit 0
EOF

    # build.sh puts the cloned depot_tools FIRST on PATH, so the gclient a
    # clone produces is the one that actually runs. The stub clone therefore
    # has to install a working gclient, not a placeholder — with a placeholder
    # every case fails for a reason that has nothing to do with the guards.
    # `git -C <dir> rev-parse HEAD` puts the verb in \$3, not \$1, so the
    # subcommand is found by scanning rather than by position. Matching on \$1
    # alone made every rev-parse fall through and answer nothing, which read
    # as "the checkout is at no revision at all".
    cat > "$bin/git" <<EOF
#!/bin/bash
echo "git \$*" >> "$log"
# The verb is the first argument that is neither an option nor the directory
# that -C consumes.
verb=""
skip_next=0
for arg in "\$@"; do
    if [ "\$skip_next" = "1" ]; then skip_next=0; continue; fi
    case "\$arg" in
        -C) skip_next=1; continue ;;
        -*) continue ;;
    esac
    verb="\$arg"; break
done
case "\$verb" in
    clone)
        # Last argument is the destination.
        dest="\${@: -1}"
        mkdir -p "\$dest"
        cp "$bin/gclient" "\$dest/gclient"
        chmod +x "\$dest/gclient"
        ;;
    rev-parse)
        # Answer for the tree being asked about: \`git -C <dir> rev-parse HEAD\`.
        # What the stub sync recorded is what the checkout "is at".
        dir="."
        prev=""
        for arg in "\$@"; do
            case "\$prev" in -C) dir="\$arg" ;; esac
            prev="\$arg"
        done
        if [ -f "\$dir/.stub-revision" ]; then
            cat "\$dir/.stub-revision"
        else
            echo "abc1234"
        fi
        ;;
esac
exit 0
EOF

    cat > "$bin/gn" <<EOF
#!/bin/bash
echo "gn \$*" >> "$log"
mkdir -p out/Release
exit 0
EOF

    # ninja produces one object and the public headers, unless the caller asked
    # for a build that gets part way and stops.
    cat > "$bin/ninja" <<EOF
#!/bin/bash
echo "ninja \$*" >> "$log"
mkdir -p out/Release/obj
printf 'not a real object' > out/Release/obj/page.o
if [ "\${STUB_NINJA_SKIP_HEADERS:-0}" != "1" ]; then
    mkdir -p public
    printf '/* fpdfview */' > public/fpdfview.h
fi
exit 0
EOF

    chmod +x "$bin"/*
}

# Run build.sh in a fresh build directory with the stubs first on PATH.
# Prints nothing on success; the caller inspects the tree and the log.
run_build() {
    local build_dir="$1" log="$2" out="$3"
    local bin="${build_dir}/.stubs"
    make_stubs "$bin" "$log"
    # So `fail` can show what the build said, from any case, without each one
    # remembering to.
    FAIL_OUTPUT="$out"
    PATH="$bin:$PATH" PDFIUM_BUILD_DIR="$build_dir" \
        bash "$ROOT/build.sh" > "$out" 2>&1
}

scratch() {
    mktemp -d "${TMPDIR:-/tmp}/pdfium-guards.XXXXXX"
}

echo "TEST9700 — a build with nothing in place produces a complete distribution"
(
    work="$(scratch)"; trap 'rm -rf "$work"' EXIT
    log="$work/log"; : > "$log"
    if ! run_build "$work/build" "$log" "$work/out"; then
        fail "a clean build did not succeed:"; tail -20 "$work/out" >&2; exit 1
    fi
    dist="$work/build/dist"
    [ -f "$dist/lib/libpdfium.a" ] || fail "no libpdfium.a in the published dist"
    [ -f "$dist/include/public/fpdfview.h" ] || fail "no headers in the published dist"
    [ -f "$dist/pdfium.pc" ] || fail "no pdfium.pc in the published dist"
    # The .pc must name where the files ARE, not the staging directory they
    # were assembled in — it is read after the rename.
    if ! grep -qx "prefix=$dist" "$dist/pdfium.pc"; then
        fail "pdfium.pc names the wrong prefix: $(grep '^prefix=' "$dist/pdfium.pc")"
    fi
    [ -d "$dist.staging" ] && fail "the staging directory survived a successful build"
    [ -d "$dist.previous" ] && fail "the previous distribution was not cleaned up"
    exit 0
)
case_result $? "a clean run publishes lib, headers and a pkg-config naming the final path"

echo "TEST9701 — a half-cloned depot_tools is replaced, not trusted"
(
    work="$(scratch)"; trap 'rm -rf "$work"' EXIT
    log="$work/log"; : > "$log"
    # What an interrupted `git clone` leaves: the directory, without the tool.
    mkdir -p "$work/build/depot_tools/.git"
    printf 'partial' > "$work/build/depot_tools/README.md"
    if ! run_build "$work/build" "$log" "$work/out"; then
        fail "a run after an interrupted depot_tools clone did not recover:"
        tail -20 "$work/out" >&2; exit 1
    fi
    [ -x "$work/build/depot_tools/gclient" ] || fail "depot_tools still has no gclient"
    grep -q "^git clone" "$log" || fail "the partial clone was reused instead of replaced"
    [ -d "$work/build/depot_tools.partial" ] && fail "the scratch clone was left behind"
    exit 0
)
case_result $? "a depot_tools directory with no gclient is discarded and re-cloned"

echo "TEST9702 — an interrupted sync is finished, not skipped"
(
    work="$(scratch)"; trap 'rm -rf "$work"' EXIT
    log="$work/log"; : > "$log"
    # What an interrupted `gclient sync` leaves: the pdfium directory, empty,
    # and no stamp. The old guard read that as "already downloaded".
    mkdir -p "$work/build/pdfium"
    if ! run_build "$work/build" "$log" "$work/out"; then
        fail "a run after an interrupted sync did not recover:"
        tail -20 "$work/out" >&2; exit 1
    fi
    grep -q "^gclient sync" "$log" || fail "sync was skipped because the directory existed"
    [ -f "$work/build/.pdfium-synced" ] || fail "no completion stamp was written"
    exit 0
)
case_result $? "a pdfium directory with no completion stamp is synced again"

echo "TEST9703 — a completed sync is not repeated"
(
    work="$(scratch)"; trap 'rm -rf "$work"' EXIT
    log="$work/log"; : > "$log"
    run_build "$work/build" "$log" "$work/out" || { fail "first build failed"; exit 1; }
    grep -q "^gclient sync" "$log" || fail "the first run did not sync at all"
    : > "$log"
    run_build "$work/build" "$log" "$work/out" || { fail "second build failed"; exit 1; }
    if grep -q "^gclient sync" "$log"; then
        fail "a finished sync was repeated — the stamp buys nothing"
    fi
    exit 0
)
case_result $? "the stamp from a finished sync is honoured on the next run"

echo "TEST9704 — a build that fails publishes nothing"
(
    work="$(scratch)"; trap 'rm -rf "$work"' EXIT
    log="$work/log"; : > "$log"
    bin="$work/build/.stubs"
    make_stubs "$bin" "$log"
    # Headers never arrive. The distribution is unusable, and the old script
    # said "Warning: Headers not copied" and shipped it anyway.
    if PATH="$bin:$PATH" PDFIUM_BUILD_DIR="$work/build" STUB_NINJA_SKIP_HEADERS=1 \
        bash "$ROOT/build.sh" > "$work/out" 2>&1; then
        fail "a build with no headers reported success"
    fi
    if [ -d "$work/build/dist" ]; then
        fail "a failed build left a distribution at $work/build/dist"
    fi
    exit 0
)
case_result $? "a failed build leaves no distribution for a consumer to link against"

echo "TEST9705 — the sync names the pinned revision, not whatever is newest"
(
    work="$(scratch)"; trap 'rm -rf "$work"' EXIT
    log="$work/log"; : > "$log"
    pinned="$(tr -d '[:space:]' < "$ROOT/pdfium-revision.txt")"
    [ -n "$pinned" ] || fail "pdfium-revision.txt is empty"
    run_build "$work/build" "$log" "$work/out" || { fail "build failed"; exit 1; }
    # An unpinned `gclient sync` takes PDFium's tip of main, which is how a
    # Windows SDK bump nobody asked for stopped this build: the revision has
    # to be part of the sync, because gclient resolves DEPS against whatever
    # it synced.
    grep -q "^gclient sync --revision pdfium@${pinned}\$" "$log" ||
        fail "the sync did not name the pinned revision; log says: $(grep '^gclient sync' "$log")"
    exit 0
)
case_result $? "the build syncs the revision this bundle pins"

echo "TEST9706 — moving the pin resyncs a tree that is already built"
(
    work="$(scratch)"; trap 'rm -rf "$work"' EXIT
    log="$work/log"; : > "$log"
    run_build "$work/build" "$log" "$work/out" || { fail "first build failed"; exit 1; }
    # The stamp records WHICH revision was synced. Recording only that a sync
    # happened would leave every machine with an existing tree on the old
    # revision after a bump, silently.
    printf '%s\n' "0000000000000000000000000000000000000000" > "$work/build/.pdfium-synced"
    : > "$log"
    run_build "$work/build" "$log" "$work/out" || { fail "second build failed"; exit 1; }
    grep -q "^gclient sync" "$log" ||
        fail "a stamp naming another revision was honoured; the pin cannot be moved"
    exit 0
)
case_result $? "a stamp from a different revision is not mistaken for this one"

echo
echo "${PASSED} passed, ${FAILED} failed"
[ "$FAILED" -eq 0 ]
