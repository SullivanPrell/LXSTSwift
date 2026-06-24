# LXSTSwift

A Swift port of [LXST](https://github.com/markqvist/LXST) — the **Lightweight
Extensible Signal Transport** — for real-time, end-to-end encrypted voice and
audio over Reticulum.

[![Platforms](https://img.shields.io/badge/platforms-iOS%2016%2B%20%7C%20macOS%2013%2B-blue)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-5.9-orange)](https://swift.org)
[![Tests](https://img.shields.io/badge/tests-245%20passing-brightgreen)](#testing)
[![License](https://img.shields.io/badge/license-Reticulum-lightgrey)](LICENSE)

LXST carries live audio (and other signals) over Reticulum links — the protocol
behind voice calls in the Reticulum ecosystem. LXSTSwift implements it with real
audio I/O via **AVFoundation**, **Opus** and **Codec2** codecs, a streaming
pipeline, and a high-level **Telephone** session manager for placing and
receiving calls. It is wire-compatible with the Python LXST reference (0.4.6).

This is part of the [ReticulumSwift stack](https://github.com/SullivanPrell/ReticulumSwift#the-reticulumswift-stack).

## Status

**At parity with Python LXST 0.4.6.** Real I/O (libopus, Codec2, AVAudioEngine),
streaming pipeline, file record/playback, filters (HP/LP/BP/AGC), and the
Telephone primitive. **245 unit tests, 0 failures.**

## Requirements

- Swift 5.9+, iOS 16+ / macOS 13+
- Depends on [ReticulumSwift](https://github.com/SullivanPrell/ReticulumSwift) 1.0.0+
- The codec2 / opus binaries are fetched automatically by SwiftPM from GitHub
  Releases (checksummed `binaryTarget`s), built from pinned source by the
  *Build binaries* workflow — a normal `git clone` + `swift build` is all you need.

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/SullivanPrell/LXSTSwift.git", from: "1.0.0")
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "LXST", package: "LXSTSwift")])
]
```

## Quick start — placing a call

```swift
import ReticulumSwift
import LXST

let stack = Reticulum(configuration: .init(storagePath: storageURL))
try stack.start()
let identity = try stack.loadOrCreateIdentity()

// A Telephone owns a delivery destination, rings, and manages call audio.
let phone = Telephone(identity: identity, transport: stack.transport)
phone.announce()                              // be reachable

phone.setRingingCallback     { caller in /* incoming call ringing */ }
phone.setEstablishedCallback { caller in /* call connected */ }
phone.setEndedCallback       { caller in /* call ended */ }

// Place a call to a peer identity (resolved from an announce).
phone.call(identity: peerIdentity, profile: .voice)

// Answer / hang up.
_ = phone.answer(identity: peerIdentity)
phone.hangup()
```

Microphone capture, Opus/Codec2 encoding, link transport, decoding, and speaker
playback are wired up automatically while a call is active. Use
`muteTransmit()` / `muteReceive()` and `setTransmitGain()` / `setReceiveGain()`
to control audio.

## Lower level — the pipeline

For non-telephony streaming (tones, files, custom sources/sinks), compose a
`Pipeline` of `Source → Codec → Sink`:

```swift
let pipeline = try Pipeline(
    source: ToneSource(frequency: 440),
    codec:  OpusCodec(),
    sink:   LineSink()            // speaker
)
pipeline.start()
// …
pipeline.stop()
pipeline.release()
```

Built-in sources (microphone, tone, Opus file, loopback), sinks (speaker, Opus
file), codecs (Raw, Opus, Codec2, Null), and filters (high/low/band-pass, AGC)
are documented in [docs/USAGE.md](docs/USAGE.md). The full protocol and component
spec is in [SPEC.md](SPEC.md).

## Documentation

- [docs/USAGE.md](docs/USAGE.md) — pipeline, sources/sinks, codecs, filters, telephony
- [SPEC.md](SPEC.md) — wire protocol and component specification
- [docs/THIRD-PARTY.md](docs/THIRD-PARTY.md) — codec2 (LGPL) / opus (BSD) notices
- [CONTRIBUTING.md](CONTRIBUTING.md) — dev workflow and rebuilding the codec binaries

## Testing

```sh
swift test
RETICULUM_LOCAL_DEPS=1 swift test     # develop against a sibling ReticulumSwift checkout
```

## License

LXSTSwift's own source is under the **Reticulum License** (no harm-capable
systems; no AI/ML training datasets) — see [LICENSE](LICENSE). It redistributes
prebuilt **codec2** (LGPL v2.1) and **opus** (BSD) binaries; see
[NOTICE](NOTICE) and [docs/THIRD-PARTY.md](docs/THIRD-PARTY.md). LXSTSwift is a
derivative work of [LXST](https://github.com/markqvist/LXST) by Mark Qvist.
