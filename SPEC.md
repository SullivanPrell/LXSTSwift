# LXSTSwift Specification

**Version:** 1.1  
**Reference implementation:** LXST 0.4.6 (Python)  
**Date:** 2026-05-22

---

## 1. Objective

A full-stack Swift implementation of the Lightweight Extensible Signal Transport (LXST) protocol,
wire-compatible with the Python reference. Targets iOS 16+ and macOS 13+ for use in the RetiOS
telephony app. Provides real-time streaming of voice and audio over Reticulum links with
end-to-end encryption inherited from the underlying stack.

**Target users:** RetiOS developers building voice-call and audio-streaming features over Reticulum.

---

## 2. Package Layout

```
LXSTSwift/
├── Package.swift
├── SPEC.md
├── Sources/
│   ├── LXST/                        # Main module
│   │   ├── LXST.swift               # APP_NAME + public re-exports
│   │   ├── Pipeline.swift           # Pipeline class
│   │   ├── Mixer.swift              # Mixer (multi-source additive)
│   │   ├── Codecs/
│   │   │   ├── Codec.swift          # Codec protocol + CodecError
│   │   │   ├── Null.swift           # Null pass-through (type 0xFF)
│   │   │   ├── Raw.swift            # Raw PCM codec (type 0x00)
│   │   │   ├── Opus.swift           # Opus codec via AVAudioConverter (type 0x01)
│   │   │   └── Codec2.swift         # Codec2 stub + CCodec2 bridge (type 0x02)
│   │   ├── Sources/
│   │   │   ├── Source.swift         # Source protocol + LocalSource/RemoteSource base
│   │   │   ├── LineSource.swift     # Microphone via AVAudioEngine
│   │   │   ├── OpusFileSource.swift # OpusFileSource (play Opus file)
│   │   │   ├── ToneSource.swift     # Sine-wave generator
│   │   │   └── Loopback.swift       # Loopback (Source+Sink, self-connects)
│   │   ├── Sinks/
│   │   │   ├── Sink.swift           # Sink protocol + LocalSink/RemoteSink base
│   │   │   ├── LineSink.swift       # Speaker via AVAudioEngine
│   │   │   └── OpusFileSink.swift   # Write Opus file
│   │   ├── Network/
│   │   │   ├── Packetizer.swift     # RemoteSink → RNS Packet
│   │   │   ├── LinkSource.swift     # RNS Link → RemoteSource
│   │   │   └── Signalling.swift     # SignallingReceiver
│   │   ├── Primitives/
│   │   │   ├── Telephony.swift      # TelephonyCall + TelephonyProfile
│   │   │   ├── FileRecorder.swift   # FileRecorder primitive
│   │   │   └── FilePlayer.swift     # FilePlayer primitive
│   │   ├── Filters/
│   │   │   ├── Filter.swift         # Filter protocol
│   │   │   ├── HighPass.swift       # High-pass filter
│   │   │   ├── LowPass.swift        # Low-pass filter
│   │   │   ├── BandPass.swift       # Band-pass filter
│   │   │   └── AGC.swift            # Automatic Gain Control
│   │   └── Audio/
│   │       └── AudioBackend.swift   # AudioBackend protocol + AVAudioEngineBackend
│   └── CCodec2/                     # C shim for libcodec2
│       ├── module.modulemap
│       └── codec2_bridge.h
├── Resources/
│   └── codec2.xcframework           # Pre-built arm64 + x86_64 slices
└── Tests/
    └── LXSTTests/
        ├── WireFormatTests.swift
        ├── CodecTests.swift
        ├── PipelineTests.swift
        ├── MixerTests.swift
        ├── NetworkTests.swift
        ├── TelephonyTests.swift
        ├── FilterTests.swift
        └── PrimitivesTests.swift
```

**Dependencies:**
- `ReticulumSwift` (local path, `@_exported import`)
- `CCodec2` (binary XCFramework target, arm64-iOS + arm64/x86_64-macOS slices)

---

## 3. Wire Protocol

### 3.1 Packet structure

LXST packets are RNS DATA packets sent on a Link. The payload is a msgpack-encoded dict:

```
{
  0x00: [signal, ...]   // FIELD_SIGNALLING — optional inband signals
  0x01: <bytes>         // FIELD_FRAMES — codec_header_byte + encoded_frame
}
```

**Constants (Python: `LXST.Network`):**
```swift
public let FIELD_SIGNALLING: UInt8 = 0x00
public let FIELD_FRAMES:     UInt8 = 0x01
```

### 3.2 Codec header bytes

The first byte of the frames payload identifies the codec (Python: `LXST.Codecs`):

| Swift constant | Value | Python constant | Codec |
|---------------|-------|-----------------|-------|
| `CODEC_NULL`   | `0xFF` | `NULL = 0xFF`   | Null (pass-through) |
| `CODEC_RAW`    | `0x00` | `RAW = 0x00`    | Raw PCM |
| `CODEC_OPUS`   | `0x01` | `OPUS = 0x01`   | Opus |
| `CODEC_CODEC2` | `0x02` | `CODEC2 = 0x02` | Codec2 |

**Functions (Python: `codec_header_byte`, `codec_type`):**
```swift
public func codecHeaderByte(for codecType: any Codec.Type) -> UInt8
public func codecType(for headerByte: UInt8) -> (any Codec.Type)?
```

### 3.3 Raw codec sub-header

When `CODEC_RAW`, the second byte encodes bit depth and channel count (Python: `Raw.BITDEPTH_*`):

```
bits 7-6: bitdepth  (00=float16  BITDEPTH_16=0x00,
                     01=float32  BITDEPTH_32=0x01,
                     10=float64  BITDEPTH_64=0x02,
                     11=float128 BITDEPTH_128=0x03)
bits 5-0: channels-1  (0..31 → 1..32 channels)
```

---

## 4. Core Abstractions

### 4.1 AudioFrame

```swift
/// A decoded audio frame: interleaved Float32 samples.
/// Python equivalent: numpy float32 array of shape (samples, channels)
public struct AudioFrame {
    public let samples: [Float]    // interleaved channel-major
    public let channelCount: Int
    public let sampleRate: Double
    public var sampleCount: Int { samples.count / max(channelCount, 1) }
    public var durationMs: Double { Double(sampleCount) / sampleRate * 1000 }
}
```

This is the currency between all pipeline stages.

### 4.2 Codec protocol

```swift
public protocol Codec: AnyObject {
    static var headerByte: UInt8 { get }            // e.g. CODEC_OPUS = 0x01

    var preferredSampleRate: Double? { get }
    var frameQuantaMs: Double?       { get }         // Python: frame_quanta_ms
    var frameMaxMs: Double?          { get }         // Python: frame_max_ms
    var validFrameMs: [Double]       { get }         // Python: valid_frame_ms
    var channels: Int?               { get set }
    var source: (any Source)?        { get set }
    var sink:   (any Sink)?          { get set }

    func encode(_ frame: AudioFrame) throws -> Data  // returns encoded bytes (no header)
    func decode(_ data: Data)        throws -> AudioFrame
}

public enum CodecError: Error {
    case unsupportedProfile
    case encoderNotConfigured
    case decoderNotConfigured
    case invalidFrame
    case notImplemented    // placeholder for Codec2 before XCFramework is wired
}
```

**Implementations:**

| Class | Python ref | `headerByte` | Notes |
|-------|------------|--------------|-------|
| `NullCodec`  | `Null`   | `0xFF` | Identity encode/decode |
| `RawCodec`   | `Raw`    | `0x00` | Float32 ↔ bytes with sub-header |
| `OpusCodec`  | `Opus`   | `0x01` | AVAudioConverter; 9 profiles |
| `Codec2Codec`| `Codec2` | `0x02` | CCodec2 XCFramework; 7 modes |

### 4.3 Source protocol

```swift
public protocol Source: AnyObject {
    var codec:       (any Codec)?    { get set }
    var sink:        (any Sink)?     { get set }
    var pipeline:    Pipeline?       { get set }
    var sampleRate:  Double          { get }
    var channelCount: Int            { get }
    var bitDepth:    Int             { get }        // Python: bitdepth (bits)
    var shouldRun:   Bool            { get }
    var targetFrameMs: Double        { get }        // Python: target_frame_ms

    func start()
    func stop()
}

open class LocalSource: Source  { ... }   // microphone, file, tone, loopback
open class RemoteSource: Source { ... }   // network-received frames
```

**Concrete Sources:**

| Class | Python ref | Default frame ms | Notes |
|-------|-----------|-----------------|-------|
| `LineSource`      | `LineSource`     | 80   | AVAudioEngine mic. Params: `filters`, `gain`, `easeIn`, `skip` |
| `OpusFileSource`  | `OpusFileSource` | 100  | Plays Opus file; params: `loop`, `timed` |
| `ToneSource`      | `ToneSource`     | 80   | Sine wave gen; params: `frequency` (400 Hz default), `gain` (0.1), `ease` (true), `easeTimeMs` (20), `channels` (1) |
| `Loopback`        | `Loopback`       | 70   | Implements both Source and Sink; self-connects for testing |

### 4.4 Sink protocol

```swift
public protocol Sink: AnyObject {
    var channels: Int?   { get }
    var sampleRate: Double { get }

    func handleFrame(_ frame: AudioFrame, from source: (any Source)?)
    func start()
    func stop()
}

open class LocalSink:  Sink { ... }
open class RemoteSink: Sink { ... }
```

**Concrete Sinks:**

| Class | Python ref | Notes |
|-------|-----------|-------|
| `LineSink`     | `LineSink`     | AVAudioEngine speaker. Params: `autodigest` (true), `lowLatency` (false) |
| `OpusFileSink` | `OpusFileSink` | Writes Opus file. Params: `path`, `autodigest` (true), `profile` (PROFILE_AUDIO_MAX) |
| `Loopback`     | `Loopback`     | Also a Sink; passes frames to itself as a Source |

### 4.5 Pipeline

```swift
public final class Pipeline {
    public let source: any Source
    public let sink:   any Sink
    public var codec:  any Codec  { get set }   // settable mid-stream (dynamic codec switch)
    public var running: Bool { get }            // Python: running property

    public init(source: any Source, codec: any Codec, sink: any Sink) throws

    public func start()
    public func stop()
}

public enum PipelineError: Error {
    case invalidSource
    case invalidSink
    case invalidCodec
}
```

- Throws `PipelineError` on bad init args
- Setting `codec` mid-stream replaces the active codec without dropping frames (mirrors Python dynamic codec switching)
- If `sink` is `Loopback`: sets `sink.sampleRate = source.sampleRate`
- If `source` is `Loopback`: sets `source._sink = sink`
- If `sink` is `Packetizer`: sets `sink.source = source`
- If `sink` is `OpusFileSink`: sets `sink.source = source`

### 4.6 Mixer

```swift
public final class Mixer: LocalSource, Sink {
    public static let maxFrames: Int = 8         // Python: MAX_FRAMES = 8

    public var targetFrameMs: Double             // Python: target_frame_ms (default 40)
    public var gain: Float = 0.0                 // dB offset applied to mixed output
    public var muted: Bool = false

    public init(targetFrameMs: Double = 40, sampleRate: Double? = nil,
                codec: (any Codec)? = nil, sink: (any Sink)? = nil, gain: Float = 0.0)

    // Python: set_gain(gain=None) — nil resets to 0.0
    public func setGain(_ gain: Float?)

    // Python: mute(mute=True) / unmute(unmute=True)
    public func mute(_ mute: Bool = true)
    public func unmute(_ unmute: Bool = true)

    // Python: set_source_max_frames(source, max_frames)
    public func setSourceMaxFrames(_ maxFrames: Int, for source: any Source)

    // Python: can_receive(from_source) — returns false if queue full
    public func canReceive(from source: any Source) -> Bool

    // Sink protocol: Python handle_frame(frame, source, decoded=False)
    public func handleFrame(_ frame: AudioFrame, from source: (any Source)?)
}
```

Mixing: additive sum of all incoming frames, normalised to Float32 [-1, 1], with gain applied. Frame accumulation window = `targetFrameMs`. Max `maxFrames` per source in queue.

---

## 5. Network Layer

### 5.1 Packetizer

```swift
/// RemoteSink that packetizes AudioFrames into RNS Packets.
/// Python: LXST.Network.Packetizer
public final class Packetizer: RemoteSink {
    public var destination: (any LXSTDestination)?
    public var source: (any Source)?
    public var transmitFailure: Bool { get }     // Python: transmit_failure
    public var onFailure: (() -> Void)?          // Python: failure_callback

    public init(destination: (any LXSTDestination)? = nil,
                onFailure: (() -> Void)? = nil)

    // Sink protocol
    public func handleFrame(_ frame: AudioFrame, from source: (any Source)?)
    public func start()
    public func stop()
}

/// Either an RNS.Link or RNS.Destination can receive LXST packets.
/// Python: `type(self.destination) == RNS.Link` check in Packetizer.handle_frame
public protocol LXSTDestination: AnyObject {}
extension Link:        LXSTDestination {}
extension Destination: LXSTDestination {}
```

**Wire format for `handleFrame`:**
1. `codec_header_byte(type(source.codec))` → 1 byte
2. `codec.encode(frame)` → N bytes
3. Concatenate: `header_byte + encoded_bytes`
4. Wrap: `{FIELD_FRAMES: combined_bytes}` → msgpack
5. Send as RNS DATA packet to `destination`

### 5.2 LinkSource

```swift
/// Receives RNS Link data packets and decodes them into AudioFrames.
/// Python: LXST.Network.LinkSource
public final class LinkSource: RemoteSource, SignallingReceiverDelegate {
    public var link:     Link
    public var sink:     (any Sink)?
    public var codec:    (any Codec)?
    public var pipeline: Pipeline?

    public init(link: Link,
                signallingProxy: (any SignallingHandler)? = nil,
                sink: (any Sink)? = nil)

    public func start()
    public func stop()
}
```

**Receive logic:**
1. Unpack msgpack from `packet.data`
2. If `FIELD_FRAMES` present: read header byte → `codec_type(header_byte)`; if codec changed, replace dynamically
3. `codec.decode(frame[1:])` → `AudioFrame`
4. `sink.handleFrame(frame, from: self)`
5. If `FIELD_SIGNALLING` present: delegate to `SignallingReceiver._packet`

### 5.3 Signalling

```swift
public protocol SignallingHandler: AnyObject {
    func signallingReceived(_ signals: [Any], from source: (any Source)?)
}

/// Python: LXST.Network.SignallingReceiver
public final class SignallingReceiver {
    public var proxy: (any SignallingHandler)?
    public init(proxy: (any SignallingHandler)? = nil)

    // Python: handle_signalling_from(source) — registers packet callback on a Link
    public func handleSignallingFrom(source: Link)

    // Python: signal(signal, destination, immediate=True)
    public func signal(_ signal: Any, to destination: any LXSTDestination, immediate: Bool = true)

    // Python: signalling_received(signals, source)
    public func signallingReceived(_ signals: [Any], from source: (any Source)?)
}
```

---

## 6. Primitives

### 6.1 Telephony

```swift
/// Python: LXST.Primitives.Telephony — PRIMITIVE_NAME = "telephony"
public let LXST_TELEPHONY_PRIMITIVE = "telephony"

/// Python: Profiles class with raw UInt8 values
public enum TelephonyProfile: UInt8, CaseIterable {
    case bandwidthUltraLow = 0x10   // Python: BANDWIDTH_ULTRA_LOW
    case bandwidthVeryLow  = 0x20   // Python: BANDWIDTH_VERY_LOW
    case bandwidthLow      = 0x30   // Python: BANDWIDTH_LOW
    case qualityMedium     = 0x40   // Python: QUALITY_MEDIUM  ← DEFAULT
    case qualityHigh       = 0x50   // Python: QUALITY_HIGH
    case qualityMax        = 0x60   // Python: QUALITY_MAX
    case latencyUltraLow   = 0x70   // Python: LATENCY_ULTRA_LOW
    case latencyLow        = 0x80   // Python: LATENCY_LOW

    // Python: profile_name(profile) → String
    public var name: String { get }
    // Python: profile_abbrevation(profile) → String  (note: typo in Python preserved)
    public var abbreviation: String { get }
    // Python: get_codec(profile) → Codec instance
    public var codec: any Codec { get }
    // Python: get_frame_time(profile) → Int (ms)
    public var frameTimeMs: Int { get }
    // Python: profile_index(profile) → Int
    public var index: Int { get }
    // Python: next_profile(profile) → TelephonyProfile (wraps around)
    public static func next(after profile: TelephonyProfile) -> TelephonyProfile
    // Python: available_profiles() → [TelephonyProfile]
    public static var available: [TelephonyProfile] { get }
}

/// Profile codec mapping (Python: Profiles.get_codec):
/// bandwidthUltraLow → Codec2(mode: .codec2_700c)    frameTimeMs = 400
/// bandwidthVeryLow  → Codec2(mode: .codec2_1600)    frameTimeMs = 320
/// bandwidthLow      → Codec2(mode: .codec2_3200)    frameTimeMs = 200
/// qualityMedium     → Opus(profile: .voiceMedium)   frameTimeMs = 60
/// qualityHigh       → Opus(profile: .voiceHigh)     frameTimeMs = 60
/// qualityMax        → Opus(profile: .voiceMax)       frameTimeMs = 60
/// latencyLow        → Opus(profile: .voiceMedium)   frameTimeMs = 20
/// latencyUltraLow   → Opus(profile: .voiceMedium)   frameTimeMs = 10

public enum TelephonyCallState {
    case idle, calling, ringing, active, ended, failed
}

public final class TelephonyCall {
    public let localIdentity: Identity
    public let destinationHash: Data
    public private(set) var state: TelephonyCallState = .idle
    public var profile: TelephonyProfile = .qualityMedium
    public var onStateChanged: ((TelephonyCallState) -> Void)?
    public var onSignallingReceived: (([Any]) -> Void)?

    public init(localIdentity: Identity, destinationHash: Data,
                profile: TelephonyProfile = .qualityMedium,
                transport: Transport)

    public func call() throws
    public func answer(link: Link) throws
    public func hangup()
    public func switchProfile(_ profile: TelephonyProfile)
}
```

**Destination name:** `lxst.telephony`

### 6.2 FileRecorder (Python: `Primitives.Recorders.FileRecorder`)

```swift
public final class FileRecorder {
    public var running: Bool { get }    // Python: running property
    public var recording: Bool { get }  // alias for running

    public init(path: URL? = nil,
                device: String? = nil,
                profile: OpusProfile = .audioMax,
                gain: Float = 0.0,
                easeIn: Double = 0.125,
                skip: Double = 0.075,
                filters: [any Filter] = [BandPass(lowCut: 25, highCut: 24000)])

    public func setSource(_ device: String?)
    public func setOutputPath(_ path: URL)
    public func start()
    public func stop()
}
```

### 6.3 FilePlayer (Python: `Primitives.Players.FilePlayer`)

```swift
public final class FilePlayer {
    public var running: Bool { get }
    public var playing: Bool { get }    // alias for running
    public var onFinished: (() -> Void)?  // Python: finished_callback

    public init(path: URL? = nil, device: String? = nil, loop: Bool = false)

    public func setSource(_ path: URL)
    public func start()
    public func stop()
}
```

---

## 7. Filters

Python: `LXST.Filters` — all implement `handle_frame(frame, samplerate)`.

```swift
public protocol Filter: AnyObject {
    func handleFrame(_ frame: AudioFrame) -> AudioFrame
}

/// Python: HighPass(cut) — high-pass at cut Hz
public final class HighPass: Filter {
    public init(cut: Double)
    public func handleFrame(_ frame: AudioFrame) -> AudioFrame
}

/// Python: LowPass(cut) — low-pass at cut Hz
public final class LowPass: Filter {
    public init(cut: Double)
    public func handleFrame(_ frame: AudioFrame) -> AudioFrame
}

/// Python: BandPass(low_cut, high_cut)
public final class BandPass: Filter {
    public init(lowCut: Double, highCut: Double)
    public func handleFrame(_ frame: AudioFrame) -> AudioFrame
}

/// Python: AGC(target_level=-12.0, max_gain=12.0, attack_time=0.0001,
///             release_time=0.002, hold_time=0.001)
public final class AGC: Filter {
    public static let defaultTargetLevel:  Double = -12.0
    public static let defaultMaxGain:      Double =  12.0
    public static let defaultAttackTime:   Double =   0.0001
    public static let defaultReleaseTime:  Double =   0.002
    public static let defaultHoldTime:     Double =   0.001

    public init(targetLevel: Double = defaultTargetLevel,
                maxGain: Double     = defaultMaxGain,
                attackTime: Double  = defaultAttackTime,
                releaseTime: Double = defaultReleaseTime,
                holdTime: Double    = defaultHoldTime)
    public func handleFrame(_ frame: AudioFrame) -> AudioFrame
}
```

Filters are implemented using **vDSP** (Accelerate framework) for performance.

---

## 8. Codec Specifications

### 8.1 Opus profiles (Python: `Opus.PROFILE_*`)

All values match Python exactly:

| Swift enum case | Python constant | Raw value | Channels | Sample rate | Bitrate ceiling |
|----------------|----------------|-----------|----------|-------------|-----------------|
| `.voiceLow`    | `PROFILE_VOICE_LOW`    | `0x00` | 1 | 8 kHz  |   6,000 bps |
| `.voiceMedium` | `PROFILE_VOICE_MEDIUM` | `0x01` | 1 | 24 kHz |   8,000 bps |
| `.voiceHigh`   | `PROFILE_VOICE_HIGH`   | `0x02` | 1 | 48 kHz |  16,000 bps |
| `.voiceMax`    | `PROFILE_VOICE_MAX`    | `0x03` | 2 | 48 kHz |  32,000 bps |
| `.audioMin`    | `PROFILE_AUDIO_MIN`    | `0x04` | 1 |  8 kHz |   8,000 bps |
| `.audioLow`    | `PROFILE_AUDIO_LOW`    | `0x05` | 1 | 12 kHz |  14,000 bps |
| `.audioMedium` | `PROFILE_AUDIO_MEDIUM` | `0x06` | 2 | 24 kHz |  28,000 bps |
| `.audioHigh`   | `PROFILE_AUDIO_HIGH`   | `0x07` | 2 | 48 kHz |  56,000 bps |
| `.audioMax`    | `PROFILE_AUDIO_MAX`    | `0x08` | 2 | 48 kHz | 128,000 bps |

Application type: `voip` for voice profiles, `audio` for audio profiles.

Frame constants: `FRAME_QUANTA_MS = 2.5`, `FRAME_MAX_MS = 60`,
`VALID_FRAME_MS = [2.5, 5, 10, 20, 40, 60]`

Max bytes per frame: `ceil((bitrateCeiling / 8) * (frameDurationMs / 1000))`

### 8.2 Codec2 modes (Python: `Codec2.CODEC2_*`)

| Swift enum case | Python constant | Mode value | Header byte |
|----------------|----------------|-----------|-------------|
| `.codec2_700c` | `CODEC2_700C`  | 700  | `0x00` |
| `.codec2_1200` | `CODEC2_1200`  | 1200 | `0x01` |
| `.codec2_1300` | `CODEC2_1300`  | 1300 | `0x02` |
| `.codec2_1400` | `CODEC2_1400`  | 1400 | `0x03` |
| `.codec2_1600` | `CODEC2_1600`  | 1600 | `0x04` |
| `.codec2_2400` | `CODEC2_2400`  | 2400 | `0x05` |
| `.codec2_3200` | `CODEC2_3200`  | 3200 | `0x06` |

Constants: `INPUT_RATE = 8000`, `OUTPUT_RATE = 8000`, `FRAME_QUANTA_MS = 40`

Default mode: `.codec2_2400` (matches Python `def __init__(self, mode=CODEC2_2400)`)

**Note:** Codec2 encode/decode wire format includes a second header byte (the mode header byte
from `MODE_HEADERS`) prepended before the encoded audio bytes, giving the receiver both the
codec type (from the outer LXST header) and the mode.

### 8.3 Raw bitdepth constants

```swift
// Python: Raw.BITDEPTH_16 = 0x00, BITDEPTH_32 = 0x01, etc.
public enum RawBitDepth: UInt8 {
    case float16  = 0x00   // Python: BITDEPTH_16
    case float32  = 0x01   // Python: BITDEPTH_32
    case float64  = 0x02   // Python: BITDEPTH_64
    case float128 = 0x03   // Python: BITDEPTH_128
}
// Python: BITDEPTHS = ["float16", "float32", "float64", "float128"]
// Python: Raw channels range: 1..32 (max = 32 channels)
// Default bitdepth: 16 (Python: def __init__(self, channels=None, bitdepth=16))
```

---

## 9. ToneSource (Python: `Generators.ToneSource`)

```swift
public final class ToneSource: LocalSource {
    public static let defaultFrameMs:   Double = 80
    public static let defaultSampleRate: Double = 48000
    public static let defaultFrequency: Double = 400
    public static let easeTimeMs:       Double = 20

    public var frequency: Double
    public var gain: Float       // Python: _gain / gain

    public init(frequency: Double = defaultFrequency,
                gain: Float      = 0.1,
                ease: Bool       = true,
                easeTimeMs: Double = easeTimeMs,
                targetFrameMs: Double = defaultFrameMs,
                codec: (any Codec)? = nil,
                sink: (any Sink)? = nil,
                channels: Int    = 1)
}
```

Generates sine waves at `frequency` Hz with optional ease-in ramp.

---

## 10. Audio Backend

```swift
public protocol AudioBackend: AnyObject {
    var sampleRate:   Double { get }
    var channelCount: Int    { get }
    var bitDepth:     Int    { get }   // bits, Python: bitdepth = 32

    func startCapture(framesPerBuffer: Int,
                      handler: @escaping (AudioFrame) -> Void) throws
    func stopCapture()

    func startPlayback(sampleRate: Double,
                       channelCount: Int) throws -> any AudioPlayer
    func stopPlayback()
}

public protocol AudioPlayer: AnyObject {
    func play(_ frame: AudioFrame)
    func flush()
}
```

**Concrete:** `AVAudioEngineBackend` — `AVAudioEngine` input tap for capture;
`AVAudioPlayerNode` for playback. `#if canImport(AVFAudio)` guard for Linux safety.

`LineSource` and `LineSink` accept an `AudioBackend?` parameter; nil → `AVAudioEngineBackend()`.

---

## 11. LXST Module Constants

```swift
public let APP_NAME = "lxst"   // Python: LXST.APP_NAME = "lxst"
```

---

## 12. Code Style

- All public API documented with `///` doc comments referencing Python source
- `AudioFrame` is the canonical currency — `Data` only at encode/decode call sites
- All audio processing on `DispatchQueue(label: "lxst.audio.*")` — never on main thread
- Mixer uses `NSLock` for thread-safe frame queue access
- `@MainActor` only for state change callbacks
- No force-unwraps in production code
- `#if canImport(AVFAudio)` around all AVAudioEngine usage
- Swift 5.9+

---

## 13. Testing Strategy

All tests use `XCTest`. **No real audio hardware.** All I/O via mock backends.

| File | Coverage |
|------|----------|
| `WireFormatTests`   | Field constants, codec header bytes, Raw sub-header encoding, msgpack round-trip |
| `CodecTests`        | Null pass-through; Raw encode/decode byte-exact; Opus profile constants (all 9); Codec2 mode constants + header bytes; `maxBytesPerFrame` formula |
| `PipelineTests`     | Source→Codec→Sink wiring, mid-stream codec switch, Loopback, PipelineError on bad args |
| `MixerTests`        | Single/multi-source, gain, mute/unmute, maxFrames overflow, `canReceive`, `setSourceMaxFrames` |
| `NetworkTests`      | Packetizer: codec header + msgpack bytes are byte-exact; LinkSource: decode round-trip; dynamic codec switch on `FIELD_FRAMES` type change |
| `TelephonyTests`    | All 8 `TelephonyProfile` raw values, names, abbreviations, frameTimeMs, codec types, `next(after:)`, `available` ordering |
| `FilterTests`       | HighPass/LowPass/BandPass constants, AGC default constants |
| `PrimitivesTests`   | TelephonyProfile golden values; FileRecorder/FilePlayer init (no I/O) |

**Mock patterns:**
- `MockAudioBackend` — pushes `[AudioFrame]` to capture handler; `MockPlayer` records played frames
- `MockSink` — records all received frames
- `MockSource` — `feed(frame:)` pushes a frame through codec→sink

**Coverage target: ≥ 80% line coverage on all non-AVAudio code**

---

## 14. Boundaries

### Always do
- Wire format (codec header byte, field values, msgpack layout) **byte-exact** with Python 0.4.6
- `AudioFrame` sample-rate conversion handled **before** codec encode (source responsibility)
- Codec2 mode header bytes match Python `MODE_HEADERS` dict byte-for-byte
- Opus bitrate ceilings match Python `profile_bitrate_ceiling` exactly (not approximations)
- `maxBytesPerFrame = ceil((bitrateCeiling / 8) * (frameDurationMs / 1000))` — identical formula
- Every new public type gets at least one positive and one negative test

### Ask first
- Adding a codec not in the Python reference (e.g., AAC, MP3)
- Changing the Packetizer msgpack key layout (breaks wire compat)
- Making `LineSource`/`LineSink` require iOS 17+ or macOS 14+ APIs

### Never do
- Import `AVFAudio` without `#if canImport(AVFAudio)` guard
- Run real audio capture/playback in tests (always use `MockAudioBackend`)
- Block the main thread in any audio path
- Store samples as `Double` anywhere in the pipeline (always `Float` / float32)

---

## 15. Open Questions / Deferred

- **vDSP filter implementations:** Define `Filter` protocol and constants in v1; full vDSP BandPass/HighPass/LowPass/AGC implementations to follow
- **RPC / shared instance:** Not applicable — Swift uses in-process references  
- **`rnphone` utility:** Out of scope
- **Codec2 XCFramework build:** Needs `lib/libcodec2.a` slices pre-built for arm64-ios + arm64/x86_64-mac; until available, `Codec2Codec.encode/decode` throws `CodecError.notImplemented`
