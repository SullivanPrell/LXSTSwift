import Foundation

/// A decoded audio frame: interleaved Float32 samples at a given sample rate.
///
/// This is the canonical currency between all LXST pipeline stages.
/// Python uses numpy float32 arrays of shape (sampleCount, channelCount);
/// Swift uses a flat `[Float]` with interleaved channel layout.
public struct AudioFrame: Equatable {
    /// Interleaved samples: `[ch0[0], ch1[0], ch0[1], ch1[1], ...]`
    public let samples: [Float]
    /// Number of channels.
    public let channelCount: Int
    /// Sample rate in Hz.
    public let sampleRate: Double

    /// Number of audio samples per channel.
    public var sampleCount: Int { samples.count / max(channelCount, 1) }

    /// Duration of this frame in milliseconds.
    public var durationMs: Double { Double(sampleCount) / sampleRate * 1000 }

    public init(samples: [Float], channelCount: Int, sampleRate: Double) {
        self.samples     = samples
        self.channelCount = channelCount
        self.sampleRate  = sampleRate
    }

    /// Convenience initialiser for a silent frame.
    public static func silence(sampleCount: Int, channelCount: Int, sampleRate: Double) -> AudioFrame {
        AudioFrame(samples: [Float](repeating: 0, count: sampleCount * channelCount),
                   channelCount: channelCount,
                   sampleRate: sampleRate)
    }
}
