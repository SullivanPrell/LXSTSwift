import Foundation

/// A combined Source+Sink that routes frames back through itself.
/// Useful for testing pipelines and as a pass-through stage.
///
/// Python: `LXST.Sources.Loopback`
/// Default target_frame_ms: 70 (Python: `def __init__(self, target_frame_ms=70, ...)`)
public final class Loopback: Source, Sink {
    /// Python: `Loopback.MAX_FRAMES = 128`
    public static let maxFrames: Int = 128

    // MARK: - Source protocol
    public var codec:          (any Codec)?  = nil
    public var sink:           (any Sink)?   = nil
    public weak var pipeline:  Pipeline?     = nil
    public private(set) var sampleRate:    Double = 48000
    public private(set) var channelCount:  Int    = 1
    public private(set) var bitDepth:      Int    = 32
    public private(set) var shouldRun:     Bool   = false
    public private(set) var targetFrameMs: Double

    // MARK: - Sink protocol
    public var channels: Int? = nil

    // Internal downstream sink (set by Pipeline when wired as a sink)
    internal var _sink: (any Sink)?

    /// Python: `def __init__(self, target_frame_ms=70, codec=None, sink=None)`
    public init(targetFrameMs: Double = 70,
                codec: (any Codec)? = nil,
                sink: (any Sink)? = nil) {
        self.targetFrameMs = targetFrameMs
        self.codec  = codec
        self._sink  = sink
    }

    // MARK: - Source lifecycle

    public func start() { shouldRun = true }
    public func stop()  { shouldRun = false }
    public func release() { stop(); codec = nil; sink = nil; _sink = nil }

    // MARK: - Sink protocol

    /// Python: `Loopback.can_receive(from_source=None)` — delegates to downstream sink
    public func canReceive(from source: (any Source)?) -> Bool {
        _sink?.canReceive(from: source) ?? true
    }

    public func handleFrame(_ frame: AudioFrame, from source: (any Source)?) {
        _sink?.handleFrame(frame, from: self)
    }
}

// Internal setter for sampleRate — used by Pipeline wiring.
// Python: `if isinstance(sink, Loopback): sink.samplerate = source.samplerate`
extension Loopback {
    internal func setSampleRate(_ rate: Double) { sampleRate = rate }
}
