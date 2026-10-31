#!/bin/bash
# Build alvr_client_core as an iOS XCFramework (ALVRClientCore) for AquaVR.
# Targets: iOS device (arm64) only.
# Pinned ALVR: 20.14.1 (submodule commit e3fd448029c795b1b2d5835c84c6588bf01bae0d).
# Based on alvr-visionos build_and_repack.sh + repack_alvr_client.sh (ios slice).
#
# Diagnostics contract: job logs are NOT readable without auth, so on ANY
# failure the full log tail is auto-dumped into GITHUB_STEP_SUMMARY (readable
# via the checks API anonymously).

set -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PROFILE=release
BUILDDIR="ALVR/target/aarch64-apple-ios/${PROFILE}"
HEADERPATH="$ROOT/ALVR/build/alvr_client_core.h"
target_framework="ALVRClientCore.framework"
target_lib="ALVRClientCore.framework/ALVRClientCore"

LOG="$ROOT/ci_build.log"
rm -f "$LOG"

main() {
    set -e

    echo "=== STEP 1: toolchain sanity ==="
    command -v cargo >/dev/null 2>&1 || { echo "ERROR: cargo not found in PATH" >&2; exit 1; }
    cargo --version
    rustc --version
    xcodebuild -version

    echo "=== STEP 2: rust target ==="
    rustup target add aarch64-apple-ios

    echo "=== STEP 3: cbindgen ==="
    if command -v cbindgen >/dev/null 2>&1; then
        cbindgen --version
    else
        echo "cbindgen not found, installing via cargo (this takes a few minutes)..."
        cargo install cbindgen --locked || { echo "ERROR: cargo install cbindgen failed" >&2; exit 1; }
        cbindgen --version || { echo "ERROR: cbindgen still not runnable" >&2; exit 1; }
    fi

    echo "=== STEP 4: clean ==="
    rm -rf "$ROOT/ALVR/target" "$ROOT/ALVR/build" alvrrepack ALVRClientCore.xcframework

    echo "=== STEP 5: unset SDKROOT ==="
    unset SDKROOT

    echo "=== STEP 6: apply AquaVR client_core patches ==="
    if git -C ALVR apply --check "$ROOT/scripts/client_core_patches.patch" 2>/dev/null; then
        git -C ALVR apply "$ROOT/scripts/client_core_patches.patch"
        echo "Applied AquaVR client_core patches"
    elif git -C ALVR apply --check --reverse "$ROOT/scripts/client_core_patches.patch" 2>/dev/null; then
        echo "AquaVR client_core patches already applied"
    else
        echo "ERROR: cannot apply client_core patches" >&2
        git -C ALVR status --porcelain || true
        exit 1
    fi

    echo "=== STEP 7: cargo build (profile $PROFILE) ==="
    CARGO_TARGET_DIR=ALVR/target cargo build \
        --manifest-path ALVR/Cargo.toml \
        --target=aarch64-apple-ios \
        -p alvr_client_core \
        --profile "$PROFILE"

    echo "--- build dir ---"
    ls -la "$BUILDDIR/"

    echo "=== STEP 8: cbindgen header ==="
    mkdir -p "$ROOT/ALVR/build"
    (cd ALVR/alvr/client_core && cbindgen --config cbindgen.toml --crate alvr_client_core --output "$HEADERPATH") || {
        echo "ERROR: cbindgen header generation failed" >&2
        exit 1
    }
    ls -la "$HEADERPATH"

    echo "=== STEP 9: pack iOS framework ==="
    mkdir -p alvrrepack/ios/"$target_framework"/Headers
    cp scripts/framework_template/ios/Info.plist alvrrepack/ios/"$target_framework"/Info.plist
    cp "$HEADERPATH" alvrrepack/ios/"$target_framework"/Headers/alvr_client_core.h
    cp "$BUILDDIR/libalvr_client_core.dylib" alvrrepack/ios/"$target_lib"
    install_name_tool -id "@rpath/$target_lib" alvrrepack/ios/"$target_lib"

    echo "=== STEP 10: create xcframework ==="
    xcodebuild -create-xcframework \
        -framework alvrrepack/ios/"$target_framework" \
        -output ALVRClientCore.xcframework

    rm -rf alvrrepack
    echo "OK: ALVRClientCore.xcframework ready at $ROOT/ALVRClientCore.xcframework"
}

# Run everything through tee so we always have a full log; the left side of the
# pipe is a subshell, so main's `set -e` cannot leak into the outer shell.
main "$@" 2>&1 | tee "$LOG"
status=$?
echo "main rc: $status"

if [ "$status" -ne 0 ]; then
    if [ -n "$GITHUB_STEP_SUMMARY" ]; then
        {
            echo "### AquaVR build failed (rc=$status) -- log tail"
            echo '```'
            tail -n 600 "$LOG" 2>/dev/null || true
            echo '```'
        } >> "$GITHUB_STEP_SUMMARY"
    fi
    tail -n 120 "$LOG" 2>/dev/null || true
fi

exit "$status"
