#!/bin/bash
# Build alvr_client_core as an iOS XCFramework (ALVRClientCore) for AquaVR.
# Targets: iOS device (arm64) only.
# Pinned ALVR: 20.14.1 (submodule commit e3fd448029c795b1b2d5835c84c6588bf01bae0d).
# Based on alvr-visionos build_and_repack.sh + repack_alvr_client.sh (ios slice).
# Run on macOS with Xcode and rustup installed.
set -e -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PROFILE=release
BUILDDIR="ALVR/target/aarch64-apple-ios/${PROFILE}"
HEADERPATH="$ROOT/ALVR/build/alvr_client_core.h"
target_framework="ALVRClientCore.framework"
target_lib="ALVRClientCore.framework/ALVRClientCore"

# On failure, dump the tail of the captured log into the run summary
# (GITHUB_STEP_SUMMARY content is readable anonymously via the checks API).
dump_tail() {
    local log="$1"
    if [ -n "$GITHUB_STEP_SUMMARY" ] && [ -f "$log" ]; then
        echo "### Build log tail (last 400 lines)" >> "$GITHUB_STEP_SUMMARY"
        echo '```' >> "$GITHUB_STEP_SUMMARY"
        tail -n 400 "$log" >> "$GITHUB_STEP_SUMMARY" || true
        echo '```' >> "$GITHUB_STEP_SUMMARY"
    fi
    tail -n 80 "$log" || true
}

command -v cargo >/dev/null 2>&1 || { echo "ERROR: cargo not found"; exit 1; }

rustup target add aarch64-apple-ios
command -v cbindgen >/dev/null 2>&1 || cargo install cbindgen

rm -rf "$ROOT/ALVR/target" "$ROOT/ALVR/build" alvrrepack ALVRClientCore.xcframework

unset SDKROOT

# Apply AquaVR USB-only patches to client_core (disable UDP discovery broadcast,
# fixed microphone sample rate without opening the mic device). Idempotent.
if git -C ALVR apply --check "$ROOT/scripts/client_core_patches.patch" 2>/dev/null; then
    git -C ALVR apply "$ROOT/scripts/client_core_patches.patch"
    echo "Applied AquaVR client_core patches"
elif git -C ALVR apply --reverse --check "$ROOT/scripts/client_core_patches.patch" 2>/dev/null; then
    echo "AquaVR client_core patches already applied"
else
    echo "ERROR: cannot apply client_core patches" >&2
    exit 1
fi

# Compile. NOTE: temporary use of the release profile for fast CI iterations;
# switch back to distribution (lto) after the first green build.
set +e
CARGO_TARGET_DIR=ALVR/target cargo build \
    --manifest-path ALVR/Cargo.toml \
    --target=aarch64-apple-ios \
    -p alvr_client_core \
    --profile "$PROFILE" \
    2>&1 | tee "$ROOT/cargo_build.log"
cargo_status=$?
set -e
if [ "$cargo_status" -ne 0 ]; then
    echo "ERROR: cargo build failed with status $cargo_status" >&2
    dump_tail "$ROOT/cargo_build.log" >&2
    exit "$cargo_status"
fi

ls -la "$BUILDDIR/"

(cd ALVR/alvr/client_core && cbindgen --config cbindgen.toml --crate alvr_client_core --output "$HEADERPATH" 2>&1) | tee "$ROOT/cbindgen.log"
cbindgen_status=$?
if [ "$cbindgen_status" -ne 0 ]; then
    echo "ERROR: cbindgen failed" >&2
    dump_tail "$ROOT/cbindgen.log" >&2
    exit "$cbindgen_status"
fi

mkdir -p alvrrepack/ios/$target_framework/Headers
cp scripts/framework_template/ios/Info.plist alvrrepack/ios/$target_framework/Info.plist
cp "$HEADERPATH" alvrrepack/ios/$target_framework/Headers/alvr_client_core.h
cp "$BUILDDIR/libalvr_client_core.dylib" alvrrepack/ios/$target_lib

install_name_tool -id "@rpath/$target_lib" alvrrepack/ios/$target_lib

xcodebuild -create-xcframework \
    -framework alvrrepack/ios/$target_framework \
    -output ALVRClientCore.xcframework

rm -rf alvrrepack

echo "OK: ALVRClientCore.xcframework ready at $ROOT/ALVRClientCore.xcframework"
