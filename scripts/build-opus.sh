#!/bin/bash
# build-opus.sh — build opus.xcframework from a pinned upstream version.
#
# Produces Resources/opus.xcframework with slices matching the committed one:
#   macos-arm64_x86_64, ios-arm64, ios-simulator-arm64_x86_64
# Each slice carries libopus.a + the four public opus headers (NO modulemap —
# the COpus Clang module is declared by codec2.xcframework's modulemap; see
# build-codec2.sh). Finishes by zipping and printing the SwiftPM checksum.
#
# Usage:
#   bash scripts/build-opus.sh            # clones the pinned tag
#   OPUS_SRC=/path/to/opus bash scripts/build-opus.sh   # use a local checkout
#
# Prereqs: Xcode + iOS SDK, cmake, git.

set -euo pipefail

OPUS_VERSION="${OPUS_VERSION:-v1.6.1}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_ROOT="${BUILD_ROOT:-/tmp/opus_build}"
XCFW="$REPO_ROOT/Resources/opus.xcframework"
NCPU="$(sysctl -n hw.logicalcpu)"

mkdir -p "$BUILD_ROOT"

# --- obtain source at the pinned tag ---
if [ -n "${OPUS_SRC:-}" ]; then
    SRC="$OPUS_SRC"
else
    SRC="$BUILD_ROOT/opus-$OPUS_VERSION"
    if [ ! -d "$SRC" ]; then
        echo "==> cloning opus $OPUS_VERSION"
        git clone --depth 1 --branch "$OPUS_VERSION" https://github.com/xiph/opus "$SRC"
    fi
fi
echo "==> opus source: $SRC"

build_slice() {            # name  extra-cmake-flags...
    local name="$1"; shift
    local dir="$BUILD_ROOT/$name"
    rm -rf "$dir"; mkdir -p "$dir"
    ( cd "$dir" && cmake "$SRC" \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF \
        -DOPUS_BUILD_PROGRAMS=OFF \
        -DOPUS_BUILD_TESTING=OFF \
        "$@" >/dev/null && cmake --build . --config Release --target opus -j"$NCPU" >/dev/null )
    # opus cmake emits libopus.a at the build root
    echo "$dir/libopus.a"
}

IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
SIM_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"

echo "==> building slices"
MAC_ARM=$(build_slice macos_arm64  -DCMAKE_OSX_ARCHITECTURES=arm64)
MAC_X86=$(build_slice macos_x86_64 -DCMAKE_OSX_ARCHITECTURES=x86_64)
IOS_ARM=$(build_slice ios_arm64    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64  -DCMAKE_OSX_SYSROOT="$IOS_SDK")
SIM_ARM=$(build_slice sim_arm64    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64  -DCMAKE_OSX_SYSROOT="$SIM_SDK")
SIM_X86=$(build_slice sim_x86_64   -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=x86_64 -DCMAKE_OSX_SYSROOT="$SIM_SDK")

echo "==> lipo universal libs"
lipo -create "$MAC_ARM" "$MAC_X86" -output "$BUILD_ROOT/libopus_macos.a"
lipo -create "$SIM_ARM" "$SIM_X86" -output "$BUILD_ROOT/libopus_sim.a"

# --- assemble per-slice header dirs (bare opus headers, no modulemap) ---
HDR="$BUILD_ROOT/opus_headers"
rm -rf "$HDR"; mkdir -p "$HDR"
for h in opus.h opus_defines.h opus_multistream.h opus_types.h; do
    cp "$SRC/include/$h" "$HDR/$h"
done

echo "==> assembling xcframework"
rm -rf "$XCFW" "$BUILD_ROOT/opus.xcframework"
xcodebuild -create-xcframework \
    -library "$BUILD_ROOT/libopus_macos.a" -headers "$HDR" \
    -library "$IOS_ARM"                     -headers "$HDR" \
    -library "$BUILD_ROOT/libopus_sim.a"    -headers "$HDR" \
    -output "$BUILD_ROOT/opus.xcframework" >/dev/null
cp -R "$BUILD_ROOT/opus.xcframework" "$XCFW"

echo "==> zip + checksum"
( cd "$REPO_ROOT/Resources" && rm -f opus.xcframework.zip && zip -q -r -y opus.xcframework.zip opus.xcframework )
echo "==> opus.xcframework.zip ready:"
swift package compute-checksum "$REPO_ROOT/Resources/opus.xcframework.zip"
