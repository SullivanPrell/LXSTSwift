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

/// A sink that receives a mixer's *reference* output—the mixed signal as it
/// is played out (before codec encoding)—for use as an echo-cancellation
/// reference.
///
/// Python: any object with `handle_reference(frame, samplerate)`
/// registered in `Mixer.reference_outs`.
public protocol ReferenceSink: AnyObject {
    func handleReference(_ frame: AudioFrame, samplerate: Double)
}

/// Multi-source audio mixer that additively combines incoming frames.
///
/// Python: `LXST.Mixer.Mixer`
/// Default target_frame_ms: 40 (Python: `def __init__(self, target_frame_ms=40, ...)`)
public final class Mixer: Source, Sink {

    // MARK: - Python class constants
    /// Maximum frames buffered per source.
    ///
    /// Python: `Mixer.MAX_FRAMES = 8`
    public static let maxFrames: Int = 8

    // MARK: - Source protocol
    /// Codec frames are encoded with.
    public var codec:          (any Codec)?  = nil
    /// Sink frames are handed to.
    public var sink:           (any Sink)?   = nil
    /// Pipeline this stage belongs to.
    public weak var pipeline:  Pipeline?     = nil
    /// Output sample rate in Hz.
    public private(set) var sampleRate:    Double
    /// Output channel count.
    public private(set) var channelCount:  Int    = 1
    /// Sample depth in bits.
    public private(set) var bitDepth:      Int    = 32
    /// Target output frame duration, in milliseconds.
    public private(set) var targetFrameMs: Double

    // MARK: - Sink protocol
    /// Channel count, or `nil` to follow the source.
    public var channels: Int? = nil

    // MARK: - Mixer control-plane state (thread-safe)
    //
    // `gain`, `muted`, `shouldRun` and `referenceOuts` are written from control
    // threads—the app/UI thread (setGain/mute/unmute), and hangup → stop() on
    // the Reticulum callback thread—while the mix loop reads them on every frame
    // from the `lxst.mixer` thread. All four are guarded by `stateLock` so a
    // control write can never race a mix-loop read (ThreadSanitizer-clean, and, for
    // `referenceOuts`, crash-safe—a Swift Array read racing a write can crash).
    //
    // `stateLock` is only ever held for the trivial load/store in the accessors
    // below—never across mixing, codec encode/decode, or sink delivery—so it
    // adds no audio-path contention. It is also never held together with
    // `insertLock`, so the two locks cannot deadlock.
    private let stateLock = NSLock()
    private var unsafeGain:          Float = 0.0
    private var unsafeMuted:         Bool  = false
    private var unsafeShouldRun:     Bool  = false
    private var unsafeReferenceOuts: [any ReferenceSink] = []

    /// dB offset applied to the mixed output. Python: `gain = 0.0`
    public var gain: Float {
        get { stateLock.lock(); defer { stateLock.unlock() }; return unsafeGain }
        set { stateLock.lock(); unsafeGain = newValue; stateLock.unlock() }
    }
    /// Whether this mixer is muted. Python: `muted = False`
    public var muted: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return unsafeMuted }
        set { stateLock.lock(); unsafeMuted = newValue; stateLock.unlock() }
    }
    /// Whether the mix loop is running.
    ///
    /// Python: `should_run`.
    public private(set) var shouldRun: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return unsafeShouldRun }
        set { stateLock.lock(); unsafeShouldRun = newValue; stateLock.unlock() }
    }

    /// Reference outputs—each receives every mixed (pre-codec) frame, for use
    /// as an echo-cancellation reference signal. Python: `Mixer.reference_outs`
    public var referenceOuts: [any ReferenceSink] {
        get { stateLock.lock(); defer { stateLock.unlock() }; return unsafeReferenceOuts }
        set { stateLock.lock(); unsafeReferenceOuts = newValue; stateLock.unlock() }
    }

    private var incomingFrames: [ObjectIdentifier: [AudioFrame]] = [:]
    private var sourceMaxFrames: [ObjectIdentifier: Int] = [:]
    /// Guards BOTH `incomingFrames` and `sourceMaxFrames`—they are read together
    /// in canReceive/handleFrame, so a single consistent lock avoids the
    /// mixed-lock data race (a Swift Dictionary read racing a write can crash).
    private let insertLock = NSLock()
    private var mixerThread: Thread?

    /// Creates a mixer producing frames of `targetFrameMs`.
    ///
    /// Python: `def __init__(self, target_frame_ms=40, samplerate=None, codec=None, sink=None, gain=0.0)`
    public init(targetFrameMs: Double = 40,
                sampleRate: Double? = nil,
                codec: (any Codec)? = nil,
                sink: (any Sink)? = nil,
                gain: Float = 0.0) {
        self.targetFrameMs = targetFrameMs
        self.sampleRate    = sampleRate ?? 48000
        self.codec  = codec
        self.sink   = sink
        self.unsafeGain  = gain
    }

    // MARK: - Gain and mute (Python: set_gain, mute, unmute)

    /// Python: `set_gain(gain=None)`—nil resets to 0.0 dB.
    public func setGain(_ gain: Float?) {
        self.gain = gain ?? 0.0
    }

    /// Mutes the mixer output, or unmutes it when `mute` is false.
    ///
    /// Python: `mute(mute=True)`
    public func mute(_ mute: Bool = true) {
        self.muted = mute
    }

    /// Unmutes the mixer output, or mutes it when `unmute` is false.
    ///
    /// Python: `unmute(unmute=True)`
    public func unmute(_ unmute: Bool = true) {
        self.muted = !unmute
    }

    // MARK: - Per-source frame limit (Python: set_source_max_frames)

    /// Sets how many frames are buffered for `source`.
    ///
    /// Python: `set_source_max_frames(source, max_frames)`
    public func setSourceMaxFrames(_ maxFrames: Int, for source: any Source) {
        insertLock.lock()
        sourceMaxFrames[ObjectIdentifier(source)] = maxFrames
        insertLock.unlock()
    }

    /// Python: `can_receive(from_source)`—returns false when the queue is full.
    public func canReceive(from source: any Source) -> Bool {
        let key = ObjectIdentifier(source)
        insertLock.lock(); defer { insertLock.unlock() }
        let limit = sourceMaxFrames[key] ?? Self.maxFrames
        let count = incomingFrames[key]?.count ?? 0
        return count < limit
    }

    // MARK: - Sink: receive a frame from a source

    /// Mixes `frame` from `source` into the output.
    ///
    /// Python: `handle_frame(frame, source, decoded=False)`
    public func handleFrame(_ frame: AudioFrame, from source: (any Source)?) {
        guard let source else { return }
        let key = ObjectIdentifier(source)

        insertLock.lock()
        let limit = sourceMaxFrames[key] ?? Self.maxFrames
        if incomingFrames[key] == nil { incomingFrames[key] = [] }
        if (incomingFrames[key]?.count ?? 0) < limit {
            incomingFrames[key]?.append(frame)
        }
        insertLock.unlock()
    }

    // MARK: - Source lifecycle

    /// Starts the mixing loop.
    public func start() {
        guard !shouldRun else { return }
        shouldRun = true
        let t = Thread { [weak self] in self?.mixerJob() }
        t.name = "lxst.mixer"
        t.start()
        mixerThread = t
    }

    /// Stops the mixing loop.
    public func stop() { shouldRun = false }
    /// Stops the mixer and drops its codec and sink.
    public func release() { stop(); codec = nil; sink = nil }

    // MARK: - Mixing loop (Python: _mixer_job)

    private func mixerJob() {
        let frameSamples = Int(sampleRate * targetFrameMs / 1000) * channelCount
        while shouldRun {
            Thread.sleep(forTimeInterval: targetFrameMs / 1000)
            guard !muted else { continue }

            insertLock.lock()
            let queues = incomingFrames
            for key in incomingFrames.keys {
                if var q = incomingFrames[key], !q.isEmpty {
                    q.removeFirst()
                    incomingFrames[key] = q
                }
            }
            insertLock.unlock()

            // Additive mix: sum all first-in-queue frames
            var mixed = [Float](repeating: 0, count: frameSamples)
            var hasSamples = false
            for (_, queue) in queues {
                guard let frame = queue.first else { continue }
                hasSamples = true
                let n = min(frame.samples.count, frameSamples)
                for i in 0..<n { mixed[i] += frame.samples[i] }
            }

            guard hasSamples else { continue }

            // Apply gain and clamp. Python: `next_frame*self._mixing_gain` with
            // `_mixing_gain = 10**(self.gain/10)` (Mixer.py:102,:113-114—the
            // power-dB seam, see DBGain).
            let gainLinear = DBGain.linear(gain)
            for i in 0..<mixed.count {
                mixed[i] = max(-1.0, min(1.0, mixed[i] * gainLinear))
            }

            let outFrame = AudioFrame(samples: mixed, channelCount: channelCount, sampleRate: sampleRate)

            // Encode through codec if set, then deliver to sink
            if let c = codec, let s = sink {
                if let encoded = try? c.encode(outFrame) {
                    if let decoded = try? c.decode(encoded) {
                        s.handleFrame(decoded, from: self)
                    }
                }
            } else {
                sink?.handleFrame(outFrame, from: self)
            }

            // Deliver the raw (pre-codec) mixed frame to any reference outputs,
            // for example, an echo suppressor tracking the played-out signal.
            // Python: `for ref in self.reference_outs: ref.handle_reference(mixed_frame, self.samplerate)`
            let refs = referenceOuts
            if !refs.isEmpty {
                for ref in refs { ref.handleReference(outFrame, samplerate: sampleRate) }
            }
        }
    }
}
