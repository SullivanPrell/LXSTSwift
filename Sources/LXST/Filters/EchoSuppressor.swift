import Foundation
import Accelerate

/// Correlation-based residual echo suppressor.
///
/// Faithful Swift port of LXST 0.4.8 `LXST.Filters.EchoSuppressor` (Python /
/// numpy). It tracks the far-end signal played out of the local speaker (fed in
/// via `handleReference`, from a `Mixer.referenceOuts`) and, when the near-end
/// microphone signal is a delayed, attenuated copy of it (acoustic echo),
/// gates the microphone output — injecting comfort noise so the far end doesn't
/// hear a hard mute.
///
/// Signal path (mirrors Python):
///  - A 12-tap Hamming-windowed sinc FIR + ×6 decimation produces a 8 kHz
///    stream used for delay estimation via normalised cross-correlation.
///  - The full-rate (48 kHz) pre-emphasised reference is retained in a circular
///    buffer so the estimated delay can be applied to align echo with mic.
///  - An adaptive coupling estimate + double-talk detection decide when to gate.
///
/// This is a DSP/quality feature, not a wire-format element: it is behaviourally
/// faithful to the reference (same algorithm and parameters), validated against
/// vectors captured from the Python implementation.
public final class EchoSuppressor: Filter, ReferenceSink {

    // MARK: - Defaults (Python DEFAULT_*)
    public static let defaultMaxDelayMs          = 550.0
    public static let defaultTrackWindowMs       = 150.0
    public static let defaultCorrelationFrameMs  = 120.0
    public static let defaultCorrelationThreshold = 0.070
    public static let defaultRmsThreshold        = 0.002
    public static let defaultEmaAlpha            = 0.2
    public static let defaultPreemphAlpha        = 0.95
    public static let defaultAccForget           = 0.92
    public static let defaultCouplingWindowS     = 5.0
    public static let defaultCouplingPercentile  = 15.0
    public static let defaultCouplingThresholdDb = -30.0
    public static let defaultGateRatioDb         = -3.0
    public static let defaultCorrThreshold       = 0.13
    public static let defaultDtdEnergyDb         = 3.0
    public static let defaultHangoverMs          = 150.0
    public static let defaultAttackMs            = 5.0
    public static let defaultReleaseMs           = 80.0
    public static let defaultRefRmsThreshold     = 0.0001
    public static let requiredCouplingHistory    = 4
    public static let defaultEstimateEveryN      = 2
    public static let defaultCngEnabled          = true
    public static let defaultCngGain             = 0.0015
    public static let defaultCngColor            = 0.98
    public static let defaultCngBlockSize        = 16384

    // MARK: - Parameters
    let maxDelayMs: Double
    let trackWindowMs: Double
    let correlationFrameMs: Double
    let correlationThreshold: Double
    let rmsThreshold: Double
    let emaAlpha: Double
    let preemphAlpha: Float
    let accForget: Double
    let estimateEveryN: Int
    let cngEnabled: Bool
    let cngGain: Float
    let cngColor: Float
    let couplingPercentile: Double
    let couplingThresholdDb: Double
    let corrThreshold: Double
    let hangoverMs: Double
    let attackMs: Double
    let releaseMs: Double
    let refRmsThreshold: Double

    // MARK: - Derived / state
    private let lock = NSLock()
    private var samplerate: Double? = nil

    // Decimator (48 kHz → 8 kHz)
    private let decimFactor = 6
    private let decimTaps: [Float]
    private var decimStateRef: [Float]
    private var decimTotalRef = 0
    private var decimStateMic: [Float]
    private var decimTotalMic = 0

    // 48 kHz reference buffer
    private var bufferSize = 0
    private var refBuffer: [Float] = []
    private var refWritePos = 0
    private var refValid = 0
    private var maxDelaySamples = 0
    private var trackWindowSamples = 0
    private var correlationSamples = 0

    // 8 kHz (downsampled) buffers
    private var samplerateDs = 0
    private var bufferSizeDs = 0
    private var refBufferDs: [Float] = []
    private var refWritePosDs = 0
    private var refValidDs = 0
    private var maxDelaySamplesDs = 0
    private var trackWindowSamplesDs = 0
    private var correlationSamplesDs = 0

    // Pre-emphasis states
    private var refPreemphState: Float = 0
    private var micPreemphState: Float = 0
    private var refPreemphStateDs: Float = 0
    private var micPreemphStateDs: Float = 0

    // Mic history (8 kHz active)
    private var micHistDs: [Float] = []
    private var micHistWriteDs = 0
    private var micHistValidDs = 0

    // Correlation accumulator (float64)
    private var corrAccDs: [Double] = []

    private var delaySamplesValue: Double? = nil
    private var delayMsValue: Double? = nil
    private var delayConfidence: Double = 0

    private var frameCount = 0

    // Coupling estimation
    private var couplingHistory: [Double] = []   // maxlen 10
    private var coupling: Double = 1e-3
    private var couplingDbValue: Double = -30.0
    private var disabledByCoupling = false
    private var currentGain: Double = 1.0
    private var hangoverSamples = 0

    // Near-end / double-talk detection
    private var lastEchoCorrelation: Double = 0
    private var nearEndActiveHold: Double = 0
    private let echoCorrelationWindow: Double = 1.0
    private var serDb: Double = 0
    private let serDbThreshold: Double = 11.0
    private let serHysteresis: Int = 2
    private var serThresholdCount = 0

    // Comfort-noise generator
    private var cngBuffer: [Float] = []
    private var cngBufferPos = 0
    private var cngState: Float = 0
    private let cngBlockSize: Int
    private var gaussianSpare: Float? = nil
    private var rng = SystemRandomNumberGenerator()

    public init(maxDelayMs: Double = defaultMaxDelayMs,
                trackWindowMs: Double = defaultTrackWindowMs,
                correlationFrameMs: Double = defaultCorrelationFrameMs,
                correlationThreshold: Double = defaultCorrelationThreshold,
                rmsThreshold: Double = defaultRmsThreshold,
                emaAlpha: Double = defaultEmaAlpha,
                preemphAlpha: Double = defaultPreemphAlpha,
                accForget: Double = defaultAccForget,
                estimateEveryN: Int = defaultEstimateEveryN,
                couplingPercentile: Double = defaultCouplingPercentile,
                couplingThresholdDb: Double = defaultCouplingThresholdDb,
                corrThreshold: Double = defaultCorrThreshold,
                hangoverMs: Double = defaultHangoverMs,
                attackMs: Double = defaultAttackMs,
                releaseMs: Double = defaultReleaseMs,
                refRmsThreshold: Double = defaultRefRmsThreshold,
                cngEnabled: Bool = defaultCngEnabled,
                cngGain: Double = defaultCngGain,
                cngColor: Double = defaultCngColor) {
        self.maxDelayMs = maxDelayMs
        self.trackWindowMs = trackWindowMs
        self.correlationFrameMs = correlationFrameMs
        self.correlationThreshold = correlationThreshold
        self.rmsThreshold = rmsThreshold
        self.emaAlpha = emaAlpha
        self.preemphAlpha = Float(preemphAlpha)
        self.accForget = accForget
        self.estimateEveryN = estimateEveryN
        self.couplingPercentile = couplingPercentile
        self.couplingThresholdDb = couplingThresholdDb
        self.corrThreshold = corrThreshold
        self.hangoverMs = hangoverMs
        self.attackMs = attackMs
        self.releaseMs = releaseMs
        self.refRmsThreshold = refRmsThreshold
        self.cngEnabled = cngEnabled
        self.cngGain = Float(cngGain)
        self.cngColor = Float(min(max(cngColor, 0.0), 0.999))
        self.cngBlockSize = EchoSuppressor.defaultCngBlockSize

        self.decimTaps = EchoSuppressor.designDecimatorTaps(numTaps: 12, cutoffHz: 3700, samplerate: 48000)
        self.decimStateRef = [Float](repeating: 0, count: decimTaps.count - 1)
        self.decimStateMic = [Float](repeating: 0, count: decimTaps.count - 1)
    }

    // MARK: - Introspection (Python properties)
    public var delayMs: Double? { delayMsValue }
    public var delaySamples: Double? { delaySamplesValue }
    public var confidence: Double { delayConfidence }
    public var couplingDb: Double { couplingDbValue }
    public var gain: Double { currentGain }

    // MARK: - Helpers

    static func toMono(_ frame: AudioFrame) -> [Float] {
        let c = max(frame.channelCount, 1)
        if c == 1 { return frame.samples }
        let n = frame.samples.count / c
        var mono = [Float](repeating: 0, count: n)
        for i in 0..<n {
            var acc: Float = 0
            for ch in 0..<c { acc += frame.samples[i * c + ch] }
            mono[i] = acc / Float(c)
        }
        return mono
    }

    /// Hamming-windowed sinc low-pass FIR, normalised to unity DC gain.
    /// Python: `_design_decimator_taps`.
    static func designDecimatorTaps(numTaps: Int, cutoffHz: Double, samplerate: Double) -> [Float] {
        let fc = cutoffHz / samplerate
        var h = [Double](repeating: 0, count: numTaps)
        var sum = 0.0
        for n in 0..<numTaps {
            let m = Double(n) - Double(numTaps - 1) / 2.0
            let x = 2.0 * fc * m
            let sinc = x == 0 ? 1.0 : sin(Double.pi * x) / (Double.pi * x)
            let win = 0.54 - 0.46 * cos(2.0 * Double.pi * Double(n) / Double(numTaps - 1))
            h[n] = 2.0 * fc * sinc * win
            sum += h[n]
        }
        return h.map { Float($0 / sum) }
    }

    /// Streaming FIR + ×decimFactor downsample. Mirrors Python `_decimate`:
    ///   buf = concat(state, x); y = convolve(buf, taps, 'valid'); out = y[m::factor]
    ///   where m = (-total) % factor; state = buf[-(L-1):]; total += len(x)
    func decimate(_ x: [Float], state: inout [Float], total: inout Int) -> [Float] {
        if x.isEmpty { return [] }
        let L = decimTaps.count
        var buf = state
        buf.append(contentsOf: x)
        // Valid convolution: y[j] = sum_m buf[j+m] * taps[L-1-m], j in 0..<x.count
        let yCount = buf.count - L + 1        // == x.count
        var y = [Float](repeating: 0, count: yCount)
        buf.withUnsafeBufferPointer { bp in
            decimTaps.withUnsafeBufferPointer { tp in
                for j in 0..<yCount {
                    var acc: Float = 0
                    for m in 0..<L { acc += bp[j + m] * tp[L - 1 - m] }
                    y[j] = acc
                }
            }
        }
        let m = ((-total) % decimFactor + decimFactor) % decimFactor
        var out: [Float] = []
        if m < yCount {
            out.reserveCapacity((yCount - m + decimFactor - 1) / decimFactor)
            var idx = m
            while idx < yCount { out.append(y[idx]); idx += decimFactor }
        }
        total += x.count
        state = Array(buf.suffix(L - 1))
        return out
    }

    /// First-order pre-emphasis. Python `_preemph`: y[0]=x[0]-a*state; y[i]=x[i]-a*x[i-1]; new state = x[-1].
    func preemph(_ x: [Float], state: Float) -> (out: [Float], state: Float) {
        if x.isEmpty { return ([], state) }
        var y = [Float](repeating: 0, count: x.count)
        let a = preemphAlpha
        y[0] = x[0] - a * state
        for i in 1..<x.count { y[i] = x[i] - a * x[i - 1] }
        return (y, x[x.count - 1])
    }

    // MARK: - Comfort noise

    private func nextGaussian() -> Float {
        if let s = gaussianSpare { gaussianSpare = nil; return s }
        // Box–Muller
        var u1 = Float.random(in: 0..<1, using: &rng)
        let u2 = Float.random(in: 0..<1, using: &rng)
        if u1 < 1e-12 { u1 = 1e-12 }
        let mag = (-2.0 * log(u1)).squareRoot()
        gaussianSpare = mag * sin(2 * .pi * u2)
        return mag * cos(2 * .pi * u2)
    }

    func generateCngBlock(_ n: Int) -> [Float] {
        var out = [Float](repeating: 0, count: n)
        var s = cngState
        let a = cngColor
        let scale = cngGain * (max(0.0, 1.0 - a * a)).squareRoot()
        for i in 0..<n {
            s = a * s + nextGaussian()
            out[i] = s * scale
        }
        cngState = s
        return out
    }

    private func getCng(_ n: Int) -> [Float] {
        guard n > 0 else { return [] }
        if cngBufferPos + n > cngBuffer.count {
            // Regenerate a block at least as large as the request. A request larger
            // than cngBlockSize (e.g. an oversized inbound frame) previously
            // produced a too-small block and the slice below overran, crashing.
            // Comfort-noise is local DSP, so sizing the block up is wire-neutral.
            cngBuffer = generateCngBlock(max(cngBlockSize, n))
            cngBufferPos = 0
        }
        let slice = Array(cngBuffer[cngBufferPos ..< cngBufferPos + n])
        cngBufferPos += n
        return slice
    }

    // MARK: - Buffer management

    private func ensureBuffer(_ sr: Double) {
        if samplerate != sr || refBuffer.isEmpty {
            samplerate = sr
            maxDelaySamples = Int(maxDelayMs / 1000.0 * sr)
            trackWindowSamples = Int(trackWindowMs / 1000.0 * sr)
            correlationSamples = Int(correlationFrameMs / 1000.0 * sr)

            bufferSize = maxDelaySamples + 16384
            refBuffer = [Float](repeating: 0, count: bufferSize)
            refWritePos = 0
            refValid = 0

            corrAccDs = []   // filled below for ds

            samplerateDs = Int(sr / Double(decimFactor))
            maxDelaySamplesDs = Int(maxDelayMs / 1000.0 * Double(samplerateDs))
            trackWindowSamplesDs = Int(trackWindowMs / 1000.0 * Double(samplerateDs))
            correlationSamplesDs = Int(correlationFrameMs / 1000.0 * Double(samplerateDs))

            bufferSizeDs = maxDelaySamplesDs + 4096
            refBufferDs = [Float](repeating: 0, count: bufferSizeDs)
            refWritePosDs = 0
            refValidDs = 0

            corrAccDs = [Double](repeating: 0, count: maxDelaySamplesDs + 1)
            micHistDs = [Float](repeating: 0, count: correlationSamplesDs)
            micHistWriteDs = 0
            micHistValidDs = 0

            decimStateRef = [Float](repeating: 0, count: decimTaps.count - 1)
            decimTotalRef = 0
            decimStateMic = [Float](repeating: 0, count: decimTaps.count - 1)
            decimTotalMic = 0
            refPreemphStateDs = 0
            micPreemphStateDs = 0

            couplingHistory.removeAll()
            coupling = 1e-3
            couplingDbValue = -30.0
            disabledByCoupling = false
            currentGain = 1.0
            hangoverSamples = 0
        }
    }

    private func appendCircular(_ buffer: inout [Float], _ writePos: inout Int, _ valid: inout Int,
                                _ size: Int, _ mono: [Float]) {
        var m = mono
        var N = m.count
        if N > size { m = Array(m.suffix(size)); N = size }
        let end = writePos + N
        if end <= size {
            for i in 0..<N { buffer[writePos + i] = m[i] }
        } else {
            let part1 = size - writePos
            for i in 0..<part1 { buffer[writePos + i] = m[i] }
            for i in 0..<(end - size) { buffer[i] = m[part1 + i] }
        }
        writePos = end % size
        valid = min(valid + N, size)
    }

    private func appendReference(_ mono: [Float]) {
        appendCircular(&refBuffer, &refWritePos, &refValid, bufferSize, mono)
    }

    private func appendReferenceDs(_ mono: [Float]) {
        appendCircular(&refBufferDs, &refWritePosDs, &refValidDs, bufferSizeDs, mono)
    }

    private func appendMicHistoryDs(_ mono: [Float]) {
        let N = mono.count
        if N >= correlationSamplesDs {
            let tail = Array(mono.suffix(correlationSamplesDs))
            for i in 0..<correlationSamplesDs { micHistDs[i] = tail[i] }
            micHistWriteDs = 0
            micHistValidDs = correlationSamplesDs
            return
        }
        let end = micHistWriteDs + N
        if end <= correlationSamplesDs {
            for i in 0..<N { micHistDs[micHistWriteDs + i] = mono[i] }
        } else {
            let part1 = correlationSamplesDs - micHistWriteDs
            for i in 0..<part1 { micHistDs[micHistWriteDs + i] = mono[i] }
            for i in 0..<(end - correlationSamplesDs) { micHistDs[i] = mono[part1 + i] }
        }
        micHistWriteDs = end % correlationSamplesDs
        micHistValidDs = min(micHistValidDs + N, correlationSamplesDs)
    }

    private func readCircular(_ buffer: [Float], _ writePos: Int, _ size: Int,
                              length rawLength: Int, valid: Int) -> [Float] {
        let length = min(rawLength, valid)
        if length <= 0 { return [] }
        let start = ((writePos - length) % size + size) % size
        let end = writePos
        if start < end { return Array(buffer[start..<end]) }
        return Array(buffer[start..<size]) + Array(buffer[0..<end])
    }

    private func getReferenceWindowDs(_ length: Int) -> [Float] {
        readCircular(refBufferDs, refWritePosDs, bufferSizeDs, length: length, valid: refValidDs)
    }

    private func getMicHistoryDs() -> [Float] {
        readCircular(micHistDs, micHistWriteDs, correlationSamplesDs,
                     length: correlationSamplesDs, valid: micHistValidDs)
    }

    private func getDelayedReference(_ delay: Int, _ length: Int) -> [Float]? {
        if delay + length > refValid { return nil }
        let start = ((refWritePos - delay - length) % bufferSize + bufferSize) % bufferSize
        let end = ((refWritePos - delay) % bufferSize + bufferSize) % bufferSize
        if start < end { return Array(refBuffer[start..<end]) }
        return Array(refBuffer[start..<bufferSize]) + Array(refBuffer[0..<end])
    }

    // MARK: - Coupling estimation

    private func updateCoupling(micEnergy: Double, refEnergy: Double, corr: Double) {
        let micEnergyThreshold = 6e-7
        let refEnergyThreshold = 6e-7
        if refEnergy > refEnergyThreshold && corr > corrThreshold && micEnergy > micEnergyThreshold {
            let ratio = micEnergy / refEnergy
            couplingHistory.append(ratio)
            if couplingHistory.count > 10 { couplingHistory.removeFirst(couplingHistory.count - 10) }

            if couplingHistory.count >= EchoSuppressor.requiredCouplingHistory {
                coupling = percentile(couplingHistory, couplingPercentile)
                couplingDbValue = 10.0 * log10(coupling + 1e-12)
                if couplingDbValue < couplingThresholdDb { disabledByCoupling = true }
                else if couplingDbValue > couplingThresholdDb + 1.5 { disabledByCoupling = false }
            }
        }
    }

    /// numpy-style linear-interpolation percentile.
    func percentile(_ values: [Double], _ p: Double) -> Double {
        if values.isEmpty { return 0 }
        let sorted = values.sorted()
        if sorted.count == 1 { return sorted[0] }
        let rank = p / 100.0 * Double(sorted.count - 1)
        let lo = Int(floor(rank))
        let hi = Int(ceil(rank))
        if lo == hi { return sorted[lo] }
        let frac = rank - Double(lo)
        return sorted[lo] * (1 - frac) + sorted[hi] * frac
    }

    // MARK: - ReferenceSink

    public func handleReference(_ frame: AudioFrame, samplerate sr: Double) {
        let mono = EchoSuppressor.toMono(frame)

        // 8 kHz path: downsample raw, then pre-emphasise.
        var monoDs = decimate(mono, state: &decimStateRef, total: &decimTotalRef)
        if !monoDs.isEmpty {
            let r = preemph(monoDs, state: refPreemphStateDs)
            monoDs = r.out; refPreemphStateDs = r.state
        }
        // 48 kHz path: pre-emphasise.
        let r48 = preemph(mono, state: refPreemphState)
        let mono48 = r48.out; refPreemphState = r48.state

        lock.lock()
        ensureBuffer(sr)
        appendReference(mono48)
        if !monoDs.isEmpty { appendReferenceDs(monoDs) }
        lock.unlock()
    }

    // MARK: - Filter

    public func handleFrame(_ frame: AudioFrame) -> AudioFrame {
        let sr = frame.sampleRate
        let channelCount = max(frame.channelCount, 1)
        let monoRaw = EchoSuppressor.toMono(frame)
        let N = monoRaw.count
        if N == 0 { return frame }

        // Downsample for delay estimation, then pre-emphasise both paths.
        let monoDs = decimate(monoRaw, state: &decimStateMic, total: &decimTotalMic)
        let r48 = preemph(monoRaw, state: micPreemphState)
        let monoPre = r48.out; micPreemphState = r48.state
        var monoPreDs = monoDs
        if !monoDs.isEmpty {
            let rd = preemph(monoDs, state: micPreemphStateDs)
            monoPreDs = rd.out; micPreemphStateDs = rd.state
        }

        frameCount += 1
        var refDelayed: [Float]? = nil

        if refValid < N + 100 { return frame }
        if let cur = samplerate, cur != sr { return frame }

        let doEstimate = (frameCount % estimateEveryN) == 0

        if !doEstimate {
            lock.lock()
            if !monoPreDs.isEmpty { appendMicHistoryDs(monoPreDs) }
            let insufficient = micHistValidDs < correlationSamplesDs / 2
            lock.unlock()
            if insufficient { return frame }
        } else {
            lock.lock()
            if !monoPreDs.isEmpty { appendMicHistoryDs(monoPreDs) }
            if micHistValidDs < correlationSamplesDs / 2 { lock.unlock(); return frame }
            let micWindow = getMicHistoryDs()
            let searchLength = min(refValidDs, maxDelaySamplesDs + micWindow.count)
            if searchLength <= micWindow.count { lock.unlock(); return frame }
            let refWindow = getReferenceWindowDs(searchLength)
            lock.unlock()

            estimateDelay(refWindow: refWindow, micWindow: micWindow)
        }

        // Fetch delayed reference aligned with the current mic frame (48 kHz).
        if let ds = delaySamplesValue {
            let intDelay = Int((ds).rounded())
            lock.lock()
            refDelayed = getDelayedReference(intDelay, N)
            lock.unlock()
        }

        // 2. Echo detection and gating.
        guard let refD = refDelayed, refD.count == N else { return frame }

        let micEnergy = meanSquare(monoPre)
        let refEnergy = meanSquare(refD)
        let micNorm = Double(norm(monoPre))
        let refNorm = Double(norm(refD))
        var corr = 0.0
        if micNorm > 1e-12 && refNorm > 1e-12 {
            corr = abs(Double(dot(monoPre, refD)) / (micNorm * refNorm))
        }

        let now = Date().timeIntervalSince1970
        let predictedEchoEnergy = coupling * refEnergy

        if corr > corrThreshold { lastEchoCorrelation = now }
        let echoCorrelated = now < lastEchoCorrelation + echoCorrelationWindow

        if micEnergy > 2e-6 {
            serDb = 10.0 * log10(micEnergy / predictedEchoEnergy + 1e-12)
        }

        let nearEnergy = max(0.0, micEnergy - predictedEchoEnergy)

        var nearEndActive = false
        let inBootstrap = couplingHistory.count < EchoSuppressor.requiredCouplingHistory
        if nearEndActiveHold > now {
            nearEndActive = true
        } else if inBootstrap {
            nearEndActive = nearEnergy > 2e-6 && corr < corrThreshold
        } else {
            if now > lastEchoCorrelation + echoCorrelationWindow { nearEndActive = true }
            if serDb > serDbThreshold {
                serThresholdCount += 1
                if serThresholdCount >= serHysteresis {
                    nearEndActive = true
                    nearEndActiveHold = now + 0.75
                }
            } else {
                serThresholdCount = 0
            }
        }

        if now < lastEchoCorrelation + echoCorrelationWindow {
            updateCoupling(micEnergy: micEnergy, refEnergy: refEnergy, corr: corr)
        }
        if disabledByCoupling { return frame }
        if couplingHistory.count < EchoSuppressor.requiredCouplingHistory { return frame }

        let shouldGate = echoCorrelated && !nearEndActive

        let frameDurationMs = Double(N) / sr * 1000.0
        let attackCoeff = 1.0 - exp(-frameDurationMs / attackMs)
        let releaseCoeff = 1.0 - exp(-frameDurationMs / releaseMs)

        var targetGain: Double
        if nearEndActive {
            targetGain = 1.0
            hangoverSamples = 0
        } else if shouldGate {
            targetGain = 0.0
            hangoverSamples = Int(hangoverMs / 1000.0 * sr)
        } else if hangoverSamples > 0 {
            targetGain = 0.0
            hangoverSamples -= N
        } else {
            targetGain = 1.0
        }

        let coeff = targetGain < currentGain ? attackCoeff : releaseCoeff
        currentGain += (targetGain - currentGain) * coeff
        if currentGain < 1e-6 { currentGain = 0.0 }
        else if currentGain > 1.0 { currentGain = 1.0 }

        let g = Float(currentGain)
        var outSamples: [Float]
        if channelCount == 1 {
            outSamples = monoRaw
            for i in 0..<outSamples.count { outSamples[i] *= g }
        } else {
            outSamples = frame.samples
            for i in 0..<outSamples.count { outSamples[i] *= g }
        }

        // Comfort-noise injection when fully gated.
        if cngEnabled && currentGain < 0.05 {
            let cng = getCng(N)
            if channelCount == 1 {
                for i in 0..<N { outSamples[i] += cng[i] }
            } else {
                for i in 0..<N {
                    for ch in 0..<channelCount {
                        let idx = i * channelCount + ch
                        outSamples[idx] = min(1.0, max(-1.0, outSamples[idx] + cng[i]))
                    }
                }
            }
        }

        return AudioFrame(samples: outSamples, channelCount: channelCount, sampleRate: sr)
    }

    // MARK: - Delay estimation

    private func estimateDelay(refWindow: [Float], micWindow: [Float]) {
        let M = refWindow.count
        let Nc = micWindow.count
        let L = M - Nc + 1
        if L <= 0 { return }

        // Cross-correlation c[k] = sum_j refWindow[k+j] * micWindow[j].
        var c = [Float](repeating: 0, count: L)
        refWindow.withUnsafeBufferPointer { rp in
            micWindow.withUnsafeBufferPointer { mp in
                for k in 0..<L {
                    var dp: Float = 0
                    vDSP_dotpr(rp.baseAddress! + k, 1, mp.baseAddress!, 1, &dp, vDSP_Length(Nc))
                    c[k] = dp
                }
            }
        }

        let micNorm = Double(norm(micWindow))
        if micNorm == 0 { return }

        // Sliding window energies via cumulative sum of squares.
        var cumsum = [Double](repeating: 0, count: M + 1)
        for i in 0..<M { cumsum[i + 1] = cumsum[i] + Double(refWindow[i]) * Double(refWindow[i]) }

        var absCorr = [Double](repeating: 0, count: L)
        for k in 0..<L {
            let wn = (cumsum[k + Nc] - cumsum[k]).squareRoot()
            absCorr[k] = wn == 0 ? 0 : abs(Double(c[k]) / (micNorm * wn))
        }

        // Accumulate (reversed) into the decaying correlation accumulator.
        for i in 0..<corrAccDs.count { corrAccDs[i] *= accForget }
        for i in 0..<L { corrAccDs[i] += absCorr[L - 1 - i] }
        let accScale = 1.0 - accForget
        var accNorm = [Double](repeating: 0, count: corrAccDs.count)
        for i in 0..<corrAccDs.count { accNorm[i] = corrAccDs[i] * accScale }

        // Peak search (tracking window if a delay is already locked).
        var bestDelayDs: Int
        var bestVal: Double
        if let ds = delaySamplesValue {
            let dEstDs = Int((ds / Double(decimFactor)).rounded())
            let dMin = max(0, dEstDs - trackWindowSamplesDs)
            let dMax = min(accNorm.count - 1, dEstDs + trackWindowSamplesDs)
            var localBest = dMin
            var localVal = accNorm[dMin]
            if dMax >= dMin {
                for i in dMin...dMax where accNorm[i] > localVal { localVal = accNorm[i]; localBest = i }
            }
            bestDelayDs = localBest
            bestVal = localVal
            if bestVal < correlationThreshold {
                let (idx, val) = argmax(accNorm)
                bestDelayDs = idx; bestVal = val
            }
        } else {
            let (idx, val) = argmax(accNorm)
            bestDelayDs = idx; bestVal = val
        }

        let rawDelayMs = Double(bestDelayDs) / Double(samplerateDs) * 1000.0
        let sr = samplerate ?? 48000

        if bestVal >= correlationThreshold {
            if delaySamplesValue == nil {
                delaySamplesValue = Double(bestDelayDs * decimFactor)
                delayMsValue = rawDelayMs
                delayConfidence = bestVal
            } else {
                let ds = emaAlpha * Double(bestDelayDs * decimFactor) + (1.0 - emaAlpha) * delaySamplesValue!
                delaySamplesValue = ds
                delayMsValue = ds / sr * 1000.0
                delayConfidence = emaAlpha * bestVal + (1.0 - emaAlpha) * delayConfidence
            }
        }
    }

    // MARK: - Small numeric helpers

    private func meanSquare(_ x: [Float]) -> Double {
        if x.isEmpty { return 0 }
        var ss: Float = 0
        vDSP_svesq(x, 1, &ss, vDSP_Length(x.count))
        return Double(ss) / Double(x.count)
    }

    private func norm(_ x: [Float]) -> Float {
        if x.isEmpty { return 0 }
        var ss: Float = 0
        vDSP_svesq(x, 1, &ss, vDSP_Length(x.count))
        return ss.squareRoot()
    }

    private func dot(_ a: [Float], _ b: [Float]) -> Float {
        var r: Float = 0
        vDSP_dotpr(a, 1, b, 1, &r, vDSP_Length(min(a.count, b.count)))
        return r
    }

    private func argmax(_ x: [Double]) -> (Int, Double) {
        var bi = 0
        var bv = x.isEmpty ? 0 : x[0]
        for i in 1..<x.count where x[i] > bv { bv = x[i]; bi = i }
        return (bi, bv)
    }
}
