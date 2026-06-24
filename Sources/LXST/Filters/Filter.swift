import Foundation
import Accelerate

// MARK: - Filter protocol

/// Base protocol for LXST audio filters.
/// Python: `LXST.Filters.Filter`
public protocol Filter: AnyObject {
    /// Process a frame and return the filtered result.
    /// Python: `Filter.handle_frame(frame, samplerate)`
    func handleFrame(_ frame: AudioFrame) -> AudioFrame
}

// MARK: - HighPass

/// Simple high-pass filter using a first-order IIR.
/// Python: `LXST.Filters.HighPass(cut)`
public final class HighPass: Filter {
    public let cut: Double   // cutoff frequency in Hz
    private var prevInput:  Float = 0
    private var prevOutput: Float = 0

    public init(cut: Double) { self.cut = cut }

    public func handleFrame(_ frame: AudioFrame) -> AudioFrame {
        let rc  = Float(1.0 / (2.0 * Double.pi * cut))
        let dt  = Float(1.0 / frame.sampleRate)
        let alpha = rc / (rc + dt)
        var out = [Float](repeating: 0, count: frame.samples.count)
        for i in 0..<frame.samples.count {
            out[i]    = alpha * (prevOutput + frame.samples[i] - prevInput)
            prevInput  = frame.samples[i]
            prevOutput = out[i]
        }
        return AudioFrame(samples: out, channelCount: frame.channelCount, sampleRate: frame.sampleRate)
    }
}

// MARK: - LowPass

/// Simple low-pass filter using a first-order IIR.
/// Python: `LXST.Filters.LowPass(cut)`
public final class LowPass: Filter {
    public let cut: Double
    private var prev: Float = 0

    public init(cut: Double) { self.cut = cut }

    public func handleFrame(_ frame: AudioFrame) -> AudioFrame {
        let rc    = Float(1.0 / (2.0 * Double.pi * cut))
        let dt    = Float(1.0 / frame.sampleRate)
        let alpha = dt / (rc + dt)
        var out   = [Float](repeating: 0, count: frame.samples.count)
        for i in 0..<frame.samples.count {
            out[i] = prev + alpha * (frame.samples[i] - prev)
            prev   = out[i]
        }
        return AudioFrame(samples: out, channelCount: frame.channelCount, sampleRate: frame.sampleRate)
    }
}

// MARK: - BandPass

/// Band-pass filter: high-pass followed by low-pass.
/// Python: `LXST.Filters.BandPass(low_cut, high_cut)`
public final class BandPass: Filter {
    public let lowCut:  Double
    public let highCut: Double
    private let hp: HighPass
    private let lp: LowPass

    public init(lowCut: Double, highCut: Double) {
        self.lowCut  = lowCut
        self.highCut = highCut
        self.hp      = HighPass(cut: lowCut)
        self.lp      = LowPass(cut: highCut)
    }

    public func handleFrame(_ frame: AudioFrame) -> AudioFrame {
        lp.handleFrame(hp.handleFrame(frame))
    }
}

// MARK: - AGC

/// Automatic Gain Control filter.
/// Python: `LXST.Filters.AGC(target_level=-12.0, max_gain=12.0, attack_time=0.0001,
///                            release_time=0.002, hold_time=0.001)`
public final class AGC: Filter {
    /// Python: default target level
    public static let defaultTargetLevel:  Double = -12.0
    public static let defaultMaxGain:      Double =  12.0
    public static let defaultAttackTime:   Double =   0.0001
    public static let defaultReleaseTime:  Double =   0.002
    public static let defaultHoldTime:     Double =   0.001

    public let targetLevel:  Double
    public let maxGain:      Double
    public let attackTime:   Double
    public let releaseTime:  Double
    public let holdTime:     Double

    private var currentGain: Float = 1.0
    private var holdSamples: Int   = 0

    public init(targetLevel:  Double = defaultTargetLevel,
                maxGain:      Double = defaultMaxGain,
                attackTime:   Double = defaultAttackTime,
                releaseTime:  Double = defaultReleaseTime,
                holdTime:     Double = defaultHoldTime) {
        self.targetLevel  = targetLevel
        self.maxGain      = maxGain
        self.attackTime   = attackTime
        self.releaseTime  = releaseTime
        self.holdTime     = holdTime
    }

    public func handleFrame(_ frame: AudioFrame) -> AudioFrame {
        guard !frame.samples.isEmpty else { return frame }

        let targetLinear  = Float(pow(10.0, targetLevel / 20.0))
        let maxGainLinear = Float(pow(10.0, maxGain / 20.0))
        let sr            = Float(frame.sampleRate)
        let attackCoeff   = Float(exp(-1.0 / (attackTime * Double(sr))))
        let releaseCoeff  = Float(exp(-1.0 / (releaseTime * Double(sr))))

        var rms: Float = 0
        vDSP_rmsqv(frame.samples, 1, &rms, vDSP_Length(frame.samples.count))

        let desiredGain: Float
        if rms > 0 { desiredGain = min(targetLinear / rms, maxGainLinear) }
        else       { desiredGain = currentGain }

        let coeff = desiredGain < currentGain ? attackCoeff : releaseCoeff
        currentGain = coeff * currentGain + (1.0 - coeff) * desiredGain

        var out = frame.samples
        vDSP_vsmul(out, 1, &currentGain, &out, 1, vDSP_Length(out.count))
        return AudioFrame(samples: out, channelCount: frame.channelCount, sampleRate: frame.sampleRate)
    }
}
