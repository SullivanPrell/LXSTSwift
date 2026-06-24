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

## The codec binaries (codec2 / opus)

`codec2.xcframework` and `opus.xcframework` are **not committed to git** — they
are built from **pinned source** and published as GitHub **Release** assets, then
consumed via `binaryTarget(url:checksum:)` in `Package.swift`. Pinned versions:
**codec2 v1.2.0**, **opus v1.6.1**.

> codec2's xcframework also carries the combined Clang modulemap that declares
> both the `CCodec2` and `COpus` modules (opus's xcframework is headers-only) —
> `scripts/build-codec2.sh` reproduces that layout, so don't hand-edit it.

### Bumping a version (the easy way)

Run the **Build binaries** workflow (Actions ▸ *Build binaries* ▸ *Run workflow*,
or `gh workflow run build-binaries.yml -f codec2_version=<tag> -f opus_version=<tag>`).
It builds both from source, publishes `codec2-<v>` / `opus-<v>` releases, and
opens a PR updating the `binaryTarget` urls + checksums. Review and merge it.

### Building locally

```sh
bash scripts/build-opus.sh      # clones opus v1.6.1, builds opus.xcframework + checksum
bash scripts/build-codec2.sh    # clones codec2 v1.2.0 (+ opus headers), builds codec2.xcframework
```

Override the pinned tag with `OPUS_VERSION=` / `CODEC2_VERSION=`, or point at a
local checkout with `OPUS_SRC=` / `CODEC2_SRC=`. Prerequisites: `cmake` + Xcode
with the iOS SDK.

> Building codec2 yourself is exactly the LGPL §6 "relink" right — see
> [docs/THIRD-PARTY.md](docs/THIRD-PARTY.md).
>
> **Note:** `opus_encoder_ctl` is variadic and can't be called from Swift, so the
> encoder uses libopus auto-bitrate (`OPUS_AUTO`), which suffices for all LXST
> stream types.

## Submitting changes

Branch from `main`, keep commits focused, ensure `swift test` is green, note any
interop implications. Contributions are licensed under the [Reticulum License](LICENSE).
