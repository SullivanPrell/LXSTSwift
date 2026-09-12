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
    /// Cutoff frequency in Hz.
    public let cut: Double   // cutoff frequency in Hz
    private var prevInput:  Float = 0
    private var prevOutput: Float = 0

    /// Creates a high-pass filter cutting below `cut`.
    public init(cut: Double) { self.cut = cut }

    /// Returns `frame` with frequencies below the cutoff attenuated.
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
    /// Cutoff frequency in Hz.
    public let cut: Double
    private var prev: Float = 0

    /// Creates a low-pass filter cutting above `cut`.
    public init(cut: Double) { self.cut = cut }

    /// Returns `frame` with frequencies above the cutoff attenuated.
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
    /// Lower cutoff frequency in Hz.
    public let lowCut:  Double
    /// Upper cutoff frequency in Hz.
    public let highCut: Double
    private let hp: HighPass
    private let lp: LowPass

    /// Creates a band-pass filter passing between `lowCut` and `highCut`.
    public init(lowCut: Double, highCut: Double) {
        self.lowCut  = lowCut
        self.highCut = highCut
        self.hp      = HighPass(cut: lowCut)
        self.lp      = LowPass(cut: highCut)
    }

    /// Returns `frame` with frequencies outside the band attenuated.
    public func handleFrame(_ frame: AudioFrame) -> AudioFrame {
        lp.handleFrame(hp.handleFrame(frame))
    }
}

// MARK: - AGC

/// Automatic Gain Control filter.
/// Python: `LXST.Filters.AGC(target_level=-12.0, max_gain=12.0, attack_time=0.0001,
///                            release_time=0.002, hold_time=0.001)`
public final class AGC: Filter {
    /// Default output target level, in decibels relative to full scale.
    ///
    /// Python: default target level
    public static let defaultTargetLevel:  Double = -12.0
    /// Default maximum gain, in decibels.
    public static let defaultMaxGain:      Double =  12.0
    /// Default gain attack time, in seconds.
    public static let defaultAttackTime:   Double =   0.0001
    /// Default gain release time, in seconds.
    public static let defaultReleaseTime:  Double =   0.002
    /// Default gain hold time, in seconds.
    public static let defaultHoldTime:     Double =   0.001

    /// Output target level, in decibels relative to full scale.
    public let targetLevel:  Double
    /// Maximum gain, in decibels.
    public let maxGain:      Double
    /// Gain attack time, in seconds.
    public let attackTime:   Double
    /// Gain release time, in seconds.
    public let releaseTime:  Double
    /// Gain hold time, in seconds.
    public let holdTime:     Double

    private var currentGain: Float = 1.0
    private var holdSamples: Int   = 0

    /// Creates a gain control with the given tuning.
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

    /// Returns `frame` with its level driven toward the target.
    public func handleFrame(_ frame: AudioFrame) -> AudioFrame {
        guard !frame.samples.isEmpty else { return frame }

        // Python: `target_linear`/`max_gain_linear = 10 ** (x / 10)`
        // (Filters.py:187-188—the power-dB seam, see DBGain).
        let targetLinear  = Float(DBGain.linear(targetLevel))
        let maxGainLinear = Float(DBGain.linear(maxGain))
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
