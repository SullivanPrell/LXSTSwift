//===----------------------------------------------------------------------===//
// Copyright (c) 2026 LXSTSwift contributors.
//
// Licensed under the Reticulum License. See LICENSE in the repository root for
// the full license text, and NOTICE for attribution of the upstream project
// this file is derived from.
//
// SPDX-License-Identifier: LicenseRef-Reticulum
//===----------------------------------------------------------------------===//

import Foundation
import CCodec2

// MARK: - Codec2 mode

/// Codec2 voice mode, matching Python `Codec2.CODEC2_*` constants exactly.
/// Python: `LXST.Codecs.Codec2`
public enum Codec2Mode: Int, CaseIterable {
    case mode700C = 700    // Python: CODEC2_700C
    case mode1200 = 1200   // Python: CODEC2_1200
    case mode1300 = 1300   // Python: CODEC2_1300
    case mode1400 = 1400   // Python: CODEC2_1400
    case mode1600 = 1600   // Python: CODEC2_1600
    case mode2400 = 2400   // Python: CODEC2_2400
    case mode3200 = 3200   // Python: CODEC2_3200

    /// C-library mode constant (codec2.h: CODEC2_MODE_*).
    /// Python: `Codec2.MODE_HEADERS` maps Python mode int → header byte,
    /// but the C library uses its own ordering. We map our enum → C constant.
    internal var cMode: Int32 {
        switch self {
        case .mode3200: return CODEC2_MODE_3200   // 0
        case .mode2400: return CODEC2_MODE_2400   // 1
        case .mode1600: return CODEC2_MODE_1600   // 2
        case .mode1400: return CODEC2_MODE_1400   // 3
        case .mode1300: return CODEC2_MODE_1300   // 4
        case .mode1200: return CODEC2_MODE_1200   // 5
        case .mode700C: return CODEC2_MODE_700C   // 8
        }
    }

    /// LXST wire sub-header byte for this mode.
    /// Python: `Codec2.MODE_HEADERS`
    public var headerByte: UInt8 {
        switch self {
        case .mode700C: return 0x00
        case .mode1200: return 0x01
        case .mode1300: return 0x02
        case .mode1400: return 0x03
        case .mode1600: return 0x04
        case .mode2400: return 0x05
        case .mode3200: return 0x06
        }
    }

    /// Decode a Codec2Mode from its LXST wire header byte.
    /// Python: `Codec2.HEADER_MODES`
    public static func from(headerByte: UInt8) -> Codec2Mode? {
        allCases.first { $0.headerByte == headerByte }
    }
}

// MARK: - Codec2 constants (Python class-level)

/// Python: `Codec2.INPUT_RATE = 8000`
public let codec2InputRate: Double = 8000
/// Python: `Codec2.OUTPUT_RATE = 8000`
public let codec2OutputRate: Double = 8000
/// Python: `Codec2.FRAME_QUANTA_MS = 40`
public let codec2FrameQuantaMs: Double = 40

// MARK: - Codec2Codec

/// Codec2 ultra-low-bandwidth voice codec backed by libcodec2 (CCodec2 XCFramework).
///
/// Python: `LXST.Codecs.Codec2` — LXST wire header byte CODEC2 = 0x02
///
/// Wire format for encoded bytes:
///   [mode_header_byte (1B)][codec2_encoded_bytes (N B)]
///
/// Default mode: `.mode2400` (Python: `def __init__(self, mode=CODEC2_2400)`)
public final class Codec2Codec: Codec {
    public static let headerByte: UInt8 = codecCodec2

    public var preferredSampleRate: Double? { codec2InputRate }
    public var frameQuantaMs:       Double? { codec2FrameQuantaMs }
    public var frameMaxMs:          Double? { nil }
    public var validFrameMs:        [Double] { [codec2FrameQuantaMs] }
    public var channels: Int? = 1
    public weak var source: (any Source)? = nil
    public var sink:   (any Sink)?   = nil

    public private(set) var mode: Codec2Mode
    public private(set) var outputSampleRate: Double = codec2OutputRate

    private var state: OpaquePointer?
    private let lock = NSLock()

    // Cached frame geometry (determined at first use)
    private var samplesPerFrame: Int = 0
    private var bytesPerFrame:   Int = 0

    /// Python: `def __init__(self, mode=CODEC2_2400)`
    public init(mode: Codec2Mode = .mode2400) {
        self.mode = mode
    }

    /// Change the active mode. Resets the codec state.
    /// Python: `Codec2.set_mode(mode)`
    public func setMode(_ newMode: Codec2Mode) {
        guard newMode != mode else { return }
        lock.lock()
        if let s = state { codec2_destroy(s); state = nil }
        lock.unlock()
        mode = newMode
    }

    deinit {
        if let s = state { codec2_destroy(s); state = nil }
    }

    // MARK: - Lazy encoder/decoder setup

    /// Returns the live codec2 state, creating it if this is the first use.
    ///
    /// The state is returned rather than only stored so callers hold a non-optional
    /// pointer; reading `state` back after this call would reintroduce an optional the
    /// function has already ruled out.
    @discardableResult
    private func ensureState() throws -> OpaquePointer {
        if let state { return state }
        guard let s = codec2_create(mode.cMode) else {
            throw CodecError.encoderNotConfigured
        }
        state = s
        samplesPerFrame = Int(codec2_samples_per_frame(s))
        let bits        = Int(codec2_bits_per_frame(s))
        bytesPerFrame   = (bits + 7) / 8   // round up to whole bytes
        return s
    }

    // MARK: - Encode

    /// Python: `Codec2.encode(frame)` — resample to 8 kHz, encode to Codec2 bytes.
    /// Wire output: `[mode_header_byte][codec2_encoded_bytes]`
    public func encode(_ frame: AudioFrame) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        let state = try ensureState()

        // Resample to 8 kHz mono if needed
        let pcm16 = toInt16Mono(frame: frame, targetRate: codec2InputRate)

        // Encode one frame at a time
        var encoded = Data([mode.headerByte])   // prepend mode header byte
        let stride = samplesPerFrame
        guard stride > 0, bytesPerFrame > 0 else { throw CodecError.encoderNotConfigured }
        var offset = 0
        while offset + stride <= pcm16.count {
            var outBytes = [UInt8](repeating: 0, count: bytesPerFrame)
            pcm16[offset ..< offset + stride].withUnsafeBufferPointer { ptr in
                guard let base = ptr.baseAddress else { return }
                codec2_encode(state, &outBytes, UnsafeMutablePointer(mutating: base))
            }
            encoded.append(contentsOf: outBytes)
            offset += stride
        }

        return encoded
    }

    // MARK: - Decode

    /// Python: `Codec2.decode(frame_bytes)` — decode Codec2 bytes to PCM Float32.
    /// Input: `[mode_header_byte][codec2_encoded_bytes]`
    public func decode(_ data: Data) throws -> AudioFrame {
        lock.lock(); defer { lock.unlock() }

        guard data.count > 1 else { throw CodecError.invalidFrame }

        // Adopt the sender's mode from the wire header byte, exactly like Python
        // `Codec2.decode` (HEADER_MODES[frame_header] → set_mode(frame_mode)):
        // a receiver decodes whatever mode the sender used, not just its own.
        // An unrecognised header keeps the current mode (Python: `else frame_mode
        // = self.mode`). This MUST run before `ensureState()` so the codec
        // geometry (samples/bytes-per-frame) matches the wire mode — otherwise
        // a different-mode frame is mis-sliced (garbage audio, or an
        // `invalidFrame` throw when its length isn't a multiple of our BPF).
        let frameHeader = data[data.startIndex]
        let frameMode = Codec2Mode.from(headerByte: frameHeader) ?? mode
        if frameMode != mode {
            if let s = state { codec2_destroy(s); state = nil }
            mode = frameMode
        }

        let state = try ensureState()

        // Drop the mode-header byte; the remainder is the codec2 payload.
        let payload = Data(data.dropFirst())
        guard bytesPerFrame > 0 else { throw CodecError.encoderNotConfigured }
        guard payload.count % bytesPerFrame == 0 else { throw CodecError.invalidFrame }

        var allSamples = [Float]()
        let frames = payload.count / bytesPerFrame

        for f in 0..<frames {
            let chunk = Data(payload[(f * bytesPerFrame) ..< ((f + 1) * bytesPerFrame)])
            var pcm16 = [Int16](repeating: 0, count: samplesPerFrame)
            chunk.withUnsafeBytes { ptr in
                guard let base = ptr.bindMemory(to: UInt8.self).baseAddress else { return }
                codec2_decode(state, &pcm16, UnsafePointer(base))
            }
            // Convert Int16 → Float32 normalised to [-1, 1]
            allSamples.append(contentsOf: pcm16.map { Float($0) / 32768.0 })
        }

        // Codec2 is 8 kHz in and out, so a sink at any other rate needs the samples converted —
        // Python: `Codec2.py:115-117`, gated on the sink existing and its rate differing.
        //
        // `bugs/018`: there was no conversion here at all. The 8 kHz samples were handed on
        // carrying the sink's rate as a *label*, which at `bandwidthUltraLow` meant 3200 real
        // samples at the head of a 19200-sample mixer frame and 16000 samples of silence after
        // it — on every one of the three Codec2 profiles, while the call reported ESTABLISHED.
        //
        // Note the sink is read through the protocol, not `as? LocalSink`: the receive path's
        // sink is a `Mixer`, which conforms to `Sink` directly, so the narrowing this replaces
        // meant the sink's rate was never consulted in a real call. Python type-checks nothing.
        guard let sinkRate = sink?.sampleRate, sinkRate != codec2OutputRate else {
            return AudioFrame(samples: allSamples, channelCount: 1, sampleRate: codec2OutputRate)
        }
        return AudioFrame(samples: Self.resampleMono(allSamples,
                                                     from: codec2OutputRate, to: sinkRate),
                          channelCount: 1,
                          sampleRate: sinkRate)
    }

    // MARK: - Helpers

    /// Linear resample of a mono Float32 buffer.
    ///
    /// The one resampler in this file, used by both directions: encode's conversion down to
    /// 8 kHz and decode's conversion up to the sink's rate. Decode had no conversion at all
    /// (`bugs/018`) partly because the encode side's was buried inside `toInt16Mono` and so was
    /// not reusable — a shape that let the two directions differ silently.
    private static func resampleMono(_ samples: [Float],
                                     from srcRate: Double,
                                     to dstRate: Double) -> [Float] {
        guard srcRate != dstRate, !samples.isEmpty else { return samples }
        let ratio = dstRate / srcRate
        // Round rather than truncate: 8 kHz → 44.1 kHz is not exactly representable, and
        // truncation loses a sample on rates that should land whole.
        let outLen = Int((Double(samples.count) * ratio).rounded())
        var out = [Float](repeating: 0, count: outLen)
        for i in 0..<outLen {
            let srcF   = Double(i) / ratio
            let srcIdx = Int(srcF)
            let frac   = Float(srcF - Double(srcIdx))
            let a      = srcIdx < samples.count ? samples[srcIdx] : 0
            let b      = srcIdx + 1 < samples.count ? samples[srcIdx + 1] : a
            out[i] = a + frac * (b - a)
        }
        return out
    }

    /// Resample and convert AudioFrame → mono Int16 at `targetRate` Hz.
    private func toInt16Mono(frame: AudioFrame, targetRate: Double) -> [Int16] {
        // Mix down to mono
        var mono = [Float](repeating: 0, count: frame.sampleCount)
        let ch = frame.channelCount
        for i in 0..<frame.sampleCount {
            var sum: Float = 0
            for c in 0..<ch { sum += frame.samples[i * ch + c] }
            mono[i] = sum / Float(ch)
        }

        mono = Self.resampleMono(mono, from: frame.sampleRate, to: targetRate)

        // Convert Float32 → Int16
        return mono.map { Int16(max(-32768, min(32767, $0 * 32768.0))) }
    }
}
