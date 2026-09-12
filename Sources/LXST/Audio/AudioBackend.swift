//===----------------------------------------------------------------------===//
// Copyright (c) 2026 LXSTSwift contributors.
//
// Licensed under the Reticulum License. See LICENSE in the repository root for
// the full license text, and NOTICE for attribution of the upstream project
// this file is derived from.
//
// SPDX-License-Identifier: LicenseRef-Reticulum
//===----------------------------------------------------------------------===//

#if canImport(AVFAudio)
import AVFAudio
#endif
import Foundation

// MARK: - AudioBackend protocol

/// Platform audio I/O abstraction. `AVAudioEngineBackend` is the concrete
/// implementation; tests use `MockAudioBackend`.
public protocol AudioBackend: AnyObject {
    var sampleRate:   Double { get }
    var channelCount: Int    { get }
    var bitDepth:     Int    { get }   // Python: bitdepth = 32

    func startCapture(framesPerBuffer: Int,
                      handler: @escaping (AudioFrame) -> Void) throws
    func stopCapture()

    func startPlayback(sampleRate: Double,
                       channelCount: Int) throws -> any AudioPlayer
    func stopPlayback()
}

/// Failures raised by an ``AudioBackend``.
public enum AudioBackendError: Error, Equatable {
  /// The requested sample rate and channel count don't describe a format
  /// `AVAudioFormat` can represent.
  case unsupportedFormat(sampleRate: Double, channelCount: Int)
}

// MARK: - AudioPlayer protocol

/// Playback handle returned by an audio backend.
public protocol AudioPlayer: AnyObject {
    func play(_ frame: AudioFrame)
    func flush()
}

// MARK: - AVAudioEngineBackend

/// Concrete audio backend using AVAudioEngine.
/// Wrapped in `#if canImport(AVFAudio)` for Linux safety.
#if canImport(AVFAudio)
/// Audio backend built on `AVAudioEngine`.
public final class AVAudioEngineBackend: AudioBackend {
    /// Capture sample rate in Hz.
    public var sampleRate:   Double = 48000
    /// Capture channel count.
    public var channelCount: Int    = 1
    /// Capture sample depth in bits.
    public var bitDepth:     Int    = 32

    private var engine:        AVAudioEngine?
    private var playerNode:    AVAudioPlayerNode?
    private var captureHandler: ((AudioFrame) -> Void)?

    /// Creates a backend capturing at `sampleRate` and `channelCount`.
    public init(sampleRate: Double = 48000, channelCount: Int = 1) {
        self.sampleRate   = sampleRate
        self.channelCount = channelCount
    }

    /// Starts capture, delivering each buffer to `handler`.
    public func startCapture(framesPerBuffer: Int,
                              handler: @escaping (AudioFrame) -> Void) throws {
        captureHandler = handler
        let engine  = AVAudioEngine()
        let input   = engine.inputNode
        let format  = input.outputFormat(forBus: 0)
        self.sampleRate   = format.sampleRate
        self.channelCount = Int(format.channelCount)

        // Derive the intended frame duration from framesPerBuffer (computed by the caller
        // at 48 kHz, so framesPerBuffer/48000 = 0.020 s).  Then compute the exact number
        // of samples needed at the ACTUAL hardware sample rate so the accumulator always
        // emits exactly that duration regardless of whether the hardware runs at 48 kHz,
        // 44.1 kHz, or anything else.  This prevents the resampler from producing
        // off-size frames that opus_encode_float rejects with OPUS_BAD_ARG.
        let frameDurationSec   = Double(framesPerBuffer) / 48000.0   // 20 ms at caller's assumed rate
        let samplesPerChannel  = max(1, Int((format.sampleRate * frameDurationSec).rounded()))
        let targetSamples      = samplesPerChannel * max(1, Int(format.channelCount))
        var accumulator = [Float]()
        accumulator.reserveCapacity(targetSamples * 2)

        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(framesPerBuffer),
                         format: format) { [weak self] buffer, _ in
            guard let self, let data = buffer.floatChannelData else { return }
            let frameLen = Int(buffer.frameLength)
            let ch       = self.channelCount
            var samples  = [Float](repeating: 0, count: frameLen * ch)
            for c in 0..<ch {
                for i in 0..<frameLen {
                    samples[i * ch + c] = data[c][i]
                }
            }

            accumulator.append(contentsOf: samples)
            while accumulator.count >= targetSamples {
                let chunk = Array(accumulator.prefix(targetSamples))
                accumulator.removeFirst(targetSamples)
                let frame = AudioFrame(samples: chunk, channelCount: ch,
                                       sampleRate: self.sampleRate)
                self.captureHandler?(frame)
            }
        }

        self.engine = engine
        try engine.start()
    }

    /// Stops capture and tears down the input tap.
    public func stopCapture() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    /// Starts playback and returns the player frames are written to.
    public func startPlayback(sampleRate: Double,
                               channelCount: Int) throws -> any AudioPlayer {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        guard channelCount > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: AVAudioChannelCount(channelCount),
                                         interleaved: false)
        else {
            throw AudioBackendError.unsupportedFormat(sampleRate: sampleRate,
                                                      channelCount: channelCount)
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        try engine.start()
        player.play()
        self.engine     = engine
        self.playerNode = player
        return AVAudioPlayerAdapter(player: player, format: format)
    }

    /// Stops playback and tears down the output node.
    public func stopPlayback() {
        playerNode?.stop()
        engine?.stop()
        engine     = nil
        playerNode = nil
    }
}

final class AVAudioPlayerAdapter: AudioPlayer {
    private let player: AVAudioPlayerNode
    private let format: AVAudioFormat

    init(player: AVAudioPlayerNode, format: AVAudioFormat) {
        self.player = player
        self.format = format
    }

    func play(_ frame: AudioFrame) {
        let frameCount = AVAudioFrameCount(frame.sampleCount)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount
        if let ptr = buffer.floatChannelData {
            // `ptr` has one entry per BUFFER-FORMAT channel; indexing it by the
            // frame's channel count crashes when they differ. Fill only the common
            // channels and guard the source index so a short/oversized frame can't
            // overrun `frame.samples`. Normal (matching) frames are unaffected.
            let bufCh = Int(format.channelCount)
            let ch = max(1, frame.channelCount)
            let usable = min(bufCh, ch)
            for c in 0..<usable {
                for i in 0..<frame.sampleCount {
                    let srcIdx = i * ch + c
                    ptr[c][i] = srcIdx < frame.samples.count ? frame.samples[srcIdx] : 0
                }
            }
        }
        player.scheduleBuffer(buffer)
    }

    func flush() { player.stop() }
}
#endif
