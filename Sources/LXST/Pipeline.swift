import Foundation

// MARK: - Pipeline

/// Connects a `Source` → `Codec` → `Sink` and manages the stream lifecycle.
///
/// Python: `LXST.Pipeline.Pipeline`
public final class Pipeline {
    public let source: any Source
    public let sink:   any Sink

    /// The active codec. Assigning a new value switches codecs mid-stream.
    /// Python: `@codec.setter` — replaces codec without dropping frames.
    public var codec: any Codec {
        get { source.codec ?? _codec }
        set {
            _codec         = newValue
            source.codec   = newValue
            newValue.sink  = sink
            newValue.source = source
        }
    }
    private var _codec: any Codec

    /// Whether the pipeline is currently running.
    /// Python: `Pipeline.running` property.
    public var running: Bool { source.shouldRun }

    /// Initialise a pipeline.
    /// Python: `Pipeline.__init__(source, codec, sink)`
    /// Throws `PipelineError` if any argument is incompatible.
    public init(source: any Source, codec: any Codec, sink: any Sink) throws {
        self.source = source
        self.sink   = sink
        self._codec = codec

        // Wire up references (matches Python @codec.setter order)
        source.pipeline = self
        source.sink     = sink
        source.codec    = codec     // Python: self.source.codec = self._codec
        codec.source    = source    // Python: self.source.codec.source = self.source
        codec.sink      = sink      // Python: self.source.codec.sink = self.sink

        // Python: `if isinstance(sink, Loopback): sink.samplerate = source.samplerate`
        if let loopback = sink as? Loopback {
            loopback.setSampleRate(source.sampleRate)
        }
        // Python: `if isinstance(source, Loopback): source._sink = sink`
        if let loopback = source as? Loopback {
            loopback._sink = sink
        }
        // Python: `if isinstance(sink, Packetizer): sink.source = source`
        if let pkt = sink as? Packetizer {
            pkt.source = source
        }
    }

    public func start() {
        guard !running else { return }
        source.start()
    }

    public func stop() {
        guard running else { return }
        source.stop()
    }

    private var released = false
    /// Release pipeline resources and stop. Idempotent.
    /// Python: `Pipeline.release()` (commit 2730af9)
    public func release() {
        guard !released else { return }
        released = true
        stop()
        source.release()
    }
}

// MARK: - PipelineError

public enum PipelineError: Error {
    /// Python: `PipelineError("Audio pipeline initialised with invalid source")`
    case invalidSource
    /// Python: `PipelineError("Audio pipeline initialised with invalid sink")`
    case invalidSink
    /// Python: `PipelineError("Audio pipeline initialised with invalid codec")`
    case invalidCodec
}
