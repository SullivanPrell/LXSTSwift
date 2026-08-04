#if canImport(AVFAudio)
import AVFAudio
#endif
import Foundation

/// Microphone audio source using AVAudioEngine (or a mock backend for testing).
///
/// Python: `LXST.Sources.LineSource`
/// Default frame_ms: 80 (Python: `DEFAULT_FRAME_MS = 80`)
public final class LineSource: LocalSource {
    public static let defaultFrameMs: Double = 80
    /// Python: `LineSource.MAX_FRAMES = 128`
    public static let maxFrames: Int = 128

    /// Convert dB gain to linear multiplier.
    /// Python: `@staticmethod linear_gain(gain_db): return 10**(gain_db/10)`
    /// (Sources.py:180 — the power-dB seam, see DBGain).
    public static func linearGain(_ gainDB: Float) -> Float {
        DBGain.linear(gainDB)
    }

    public var filters: [any Filter] = []
    public var gain: Float = 0.0
    public var easeIn: Double = 0.0
    public var skip: Double = 0.0

    /// Called when `startCapture` throws (e.g. "could not make an audio connection").
    /// Allows callers to surface hardware errors that would otherwise be silently dropped.
    public var onStartError: ((Error) -> Void)?

    private var backend: (any AudioBackend)?

    /// Python: `LineSource.__init__(preferred_device, target_frame_ms, codec, sink, filters, gain, ease_in, skip)`
    public init(device: String? = nil,
                targetFrameMs: Double = LineSource.defaultFrameMs,
                codec: (any Codec)? = nil,
                sink: (any Sink)?   = nil,
                filters: [any Filter] = [],
                gain: Float = 0.0,
                easeIn: Double = 0.0,
                skip: Double = 0.0,
                backend: (any AudioBackend)? = nil) {
        super.init()
        self.targetFrameMs = targetFrameMs
        self.codec   = codec
        self.sink    = sink
        self.filters = filters
        self.gain    = gain
        self.easeIn  = easeIn
        self.skip    = skip
        self.backend = backend
    }

    public override func start() {
        guard !shouldRun else { return }
        super.start()
        let framesPerBuffer = Int(sampleRate * targetFrameMs / 1000)
        do {
            try backend?.startCapture(framesPerBuffer: framesPerBuffer) { [weak self] frame in
                self?.deliver(frame)
            }
        } catch {
            onStartError?(error)
        }
    }

    public override func stop() {
        super.stop()
        backend?.stopCapture()
    }

    private func deliver(_ frame: AudioFrame) {
        var processed = frame
        for f in filters { processed = f.handleFrame(processed) }
        if gain != 0 {
            // Python: `frame_samples *= self.__gain` where
            // `__gain = self.linear_gain(self.gain)` (Sources.py:199,:270).
            let g = Self.linearGain(gain)
            processed = AudioFrame(samples: processed.samples.map { $0 * g },
                                   channelCount: processed.channelCount,
                                   sampleRate: processed.sampleRate)
        }
        sink?.handleFrame(processed, from: self)
    }
}
