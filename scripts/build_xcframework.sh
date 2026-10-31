#!/bin/bash
# Build alvr_client_core as an iOS XCFramework (ALVRClientCore) for AquaVR.
# Targets: iOS device (arm64) only.
# Pinned ALVR: 20.14.1 (submodule commit e3fd448029c795b1b2d5835c84c6588bf01bae0d).
# Based on alvr-visionos build_and_repack.sh + repack_alvr_client.sh (ios slice).
# Run on macOS with Xcode and rustup installed.
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BUILDDIR="ALVR/target/aarch64-apple-ios/distribution"
HEADERPATH="$ROOT/ALVR/build/alvr_client_core.h"
target_framework="ALVRClientCore.framework"
target_lib="ALVRClientCore.framework/ALVRClientCore"

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

CARGO_TARGET_DIR=ALVR/target cargo build \
    --manifest-path ALVR/Cargo.toml \
    --target=aarch64-apple-ios \
    -p alvr_client_core \
    --profile distribution

mkdir -p "$ROOT/ALVR/build"
(cd ALVR/alvr/client_core && cbindgen --config cbindgen.toml --crate alvr_client_core --output "$HEADERPATH")

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
