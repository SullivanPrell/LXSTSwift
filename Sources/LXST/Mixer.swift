import Foundation

/// Multi-source audio mixer that additively combines incoming frames.
///
/// Python: `LXST.Mixer.Mixer`
/// Default target_frame_ms: 40 (Python: `def __init__(self, target_frame_ms=40, ...)`)
public final class Mixer: Source, Sink {

    // MARK: - Python class constants
    /// Python: `Mixer.MAX_FRAMES = 8`
    public static let maxFrames: Int = 8

    // MARK: - Source protocol
    public var codec:          (any Codec)?  = nil
    public var sink:           (any Sink)?   = nil
    public weak var pipeline:  Pipeline?     = nil
    public private(set) var sampleRate:    Double
    public private(set) var channelCount:  Int    = 1
    public private(set) var bitDepth:      Int    = 32
    public private(set) var shouldRun:     Bool   = false
    public private(set) var targetFrameMs: Double

    // MARK: - Sink protocol
    public var channels: Int? = nil

    // MARK: - Mixer state
    /// dB offset applied to the mixed output. Python: `gain = 0.0`
    public var gain: Float = 0.0
    /// Whether this mixer is muted. Python: `muted = False`
    public var muted: Bool = false

    private var incomingFrames: [ObjectIdentifier: [AudioFrame]] = [:]
    private var sourceMaxFrames: [ObjectIdentifier: Int] = [:]
    private let mixerLock = NSLock()
    private let insertLock = NSLock()
    private var mixerThread: Thread?

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
        self.gain   = gain
    }

    // MARK: - Gain and mute (Python: set_gain, mute, unmute)

    /// Python: `set_gain(gain=None)` — nil resets to 0.0 dB.
    public func setGain(_ gain: Float?) {
        self.gain = gain ?? 0.0
    }

    /// Python: `mute(mute=True)`
    public func mute(_ mute: Bool = true) {
        self.muted = mute
    }

    /// Python: `unmute(unmute=True)`
    public func unmute(_ unmute: Bool = true) {
        self.muted = !unmute
    }

    // MARK: - Per-source frame limit (Python: set_source_max_frames)

    /// Python: `set_source_max_frames(source, max_frames)`
    public func setSourceMaxFrames(_ maxFrames: Int, for source: any Source) {
        mixerLock.lock()
        sourceMaxFrames[ObjectIdentifier(source)] = maxFrames
        mixerLock.unlock()
    }

    /// Python: `can_receive(from_source)` — returns false when the queue is full.
    public func canReceive(from source: any Source) -> Bool {
        let key = ObjectIdentifier(source)
        let limit = sourceMaxFrames[key] ?? Self.maxFrames
        let count = incomingFrames[key]?.count ?? 0
        return count < limit
    }

    // MARK: - Sink: receive a frame from a source

    /// Python: `handle_frame(frame, source, decoded=False)`
    public func handleFrame(_ frame: AudioFrame, from source: (any Source)?) {
        guard let source else { return }
        let key = ObjectIdentifier(source)
        let limit = sourceMaxFrames[key] ?? Self.maxFrames

        insertLock.lock()
        if incomingFrames[key] == nil { incomingFrames[key] = [] }
        if (incomingFrames[key]?.count ?? 0) < limit {
            incomingFrames[key]?.append(frame)
        }
        insertLock.unlock()
    }

    // MARK: - Source lifecycle

    public func start() {
        guard !shouldRun else { return }
        shouldRun = true
        let t = Thread { [weak self] in self?.mixerJob() }
        t.name = "lxst.mixer"
        t.start()
        mixerThread = t
    }

    public func stop() { shouldRun = false }
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

            // Apply gain and clamp
            let gainLinear = pow(10.0, Float(gain) / 20.0)
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
        }
    }
}
