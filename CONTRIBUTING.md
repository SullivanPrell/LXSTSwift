# Contributing to LXSTSwift

LXSTSwift targets **wire compatibility with Python LXST**
(<https://github.com/markqvist/LXST>) and real audio I/O on Apple platforms.

## Ground rules

- **Test-driven**: failing test first, implement to green, commit. Keep
  `swift test` at 245/0.
- **Mind retain cycles**: the audio graph (Pipeline ↔ Source ↔ Codec ↔ Sink)
  uses `weak` references in the right places, mirroring Python's `release()`.
  Always `release()` a pipeline when done, and prefer `weak self` in audio
  callbacks.

## Setup

```sh
git clone https://github.com/SullivanPrell/LXSTSwift.git
cd LXSTSwift
swift test
```

By default the package resolves ReticulumSwift from its published release. To
develop both at once, check out ReticulumSwift as a sibling directory and set:

```sh
RETICULUM_LOCAL_DEPS=1 swift test
```

## Rebuilding the codec binaries

`Resources/codec2.xcframework` and `Resources/opus.xcframework` are prebuilt
static libraries (committed directly). You only need to rebuild them when bumping
codec versions. Prerequisites: `brew install cmake` and Xcode with the iOS SDK.

### codec2 (LGPL v2.1)

```sh
git clone https://github.com/drowe67/codec2
cd codec2
BUILD_DIR=/tmp/codec2_build

for arch_cfg in \
  "macos_arm64:-DCMAKE_OSX_ARCHITECTURES=arm64" \
  "macos_x86_64:-DCMAKE_OSX_ARCHITECTURES=x86_64" \
  "ios_arm64:-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_SYSROOT=$(xcrun --sdk iphoneos --show-sdk-path)"; do
  name="${arch_cfg%%:*}"; cfg="${arch_cfg#*:}"
  mkdir -p "$BUILD_DIR/$name" && (cd "$BUILD_DIR/$name" && \
    cmake "$OLDPWD" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF $cfg && \
    make -j"$(sysctl -n hw.logicalcpu)" codec2)
done

lipo -create "$BUILD_DIR"/macos_arm64/src/libcodec2.a \
             "$BUILD_DIR"/macos_x86_64/src/libcodec2.a \
             -output "$BUILD_DIR"/libcodec2_macos.a

xcodebuild -create-xcframework \
  -library "$BUILD_DIR"/libcodec2_macos.a -headers src/ \
  -library "$BUILD_DIR"/ios_arm64/src/libcodec2.a -headers src/ \
  -output /tmp/codec2.xcframework
# then replace Resources/codec2.xcframework with /tmp/codec2.xcframework
```

> Building codec2 yourself and replacing the bundled binary is exactly the LGPL
> §6 "relink" right — see [docs/THIRD-PARTY.md](docs/THIRD-PARTY.md).

### opus (BSD 3-Clause)

The same pattern with `https://gitlab.xiph.org/xiph/opus`, headers in `include/`,
output `Resources/opus.xcframework`.

> **Note:** `opus_encoder_ctl` is variadic and can't be called from Swift, so the
> encoder uses libopus auto-bitrate (`OPUS_AUTO`), which suffices for all LXST
> stream types.

After rebuilding, run `swift build` and `swift test`, and commit the regenerated
binaries.

## Submitting changes

Branch from `main`, keep commits focused, ensure `swift test` is green, note any
interop implications. Contributions are licensed under the [Reticulum License](LICENSE).
