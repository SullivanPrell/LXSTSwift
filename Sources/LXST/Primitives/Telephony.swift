import Foundation

// MARK: - PRIMITIVE_NAME

/// Python: `LXST.Primitives.Telephony.PRIMITIVE_NAME = "telephony"`
public let LXST_TELEPHONY_PRIMITIVE = "telephony"

// MARK: - SignallingStatus

/// Inband signalling status codes.
///
/// Python: `LXST.Primitives.Telephony.Signalling` class constants.
/// Values are sent as raw UInt8 in signalling packets.
public enum SignallingStatus: UInt8, Equatable, CaseIterable {
    case busy        = 0x00   // Python: STATUS_BUSY
    case rejected    = 0x01   // Python: STATUS_REJECTED
    case calling     = 0x02   // Python: STATUS_CALLING
    case available   = 0x03   // Python: STATUS_AVAILABLE
    case ringing     = 0x04   // Python: STATUS_RINGING
    case connecting  = 0x05   // Python: STATUS_CONNECTING
    case established = 0x06   // Python: STATUS_ESTABLISHED

    /// Statuses that automatically update `Telephone.callStatus` when received.
    /// Python: `Signalling.AUTO_STATUS_CODES = [CALLING, AVAILABLE, RINGING, CONNECTING, ESTABLISHED]`
    public static let autoStatusCodes: [SignallingStatus] = [
        .calling, .available, .ringing, .connecting, .established
    ]
}

/// Marker byte added to `TelephonyProfile.rawValue` to signal a preferred codec profile.
/// Python: `Signalling.PREFERRED_PROFILE = 0xFF`
public let SIGNALLING_PREFERRED_PROFILE: UInt8 = 0xFF

// MARK: - AllowedCallers

/// Controls which callers a `Telephone` accepts.
/// Python: `Telephone.ALLOW_ALL = 0xFF`, `Telephone.ALLOW_NONE = 0xFE`
public enum AllowedCallers: UInt8 {
    case allowAll  = 0xFF   // Python: ALLOW_ALL
    case allowNone = 0xFE   // Python: ALLOW_NONE
}

// MARK: - TelephonyProfile

/// Voice call quality/bandwidth profile, matching Python `Profiles` class raw values.
public enum TelephonyProfile: UInt8, CaseIterable {
    case bandwidthUltraLow = 0x10   // Python: BANDWIDTH_ULTRA_LOW
    case bandwidthVeryLow  = 0x20   // Python: BANDWIDTH_VERY_LOW
    case bandwidthLow      = 0x30   // Python: BANDWIDTH_LOW
    case qualityMedium     = 0x40   // Python: QUALITY_MEDIUM  ← DEFAULT
    case qualityHigh       = 0x50   // Python: QUALITY_HIGH
    case qualityMax        = 0x60   // Python: QUALITY_MAX
    case latencyUltraLow   = 0x70   // Python: LATENCY_ULTRA_LOW
    case latencyLow        = 0x80   // Python: LATENCY_LOW

    public static let defaultProfile: TelephonyProfile = .qualityMedium

    /// Python: `available_profiles()` — ordered list
    public static var available: [TelephonyProfile] {
        [.bandwidthUltraLow, .bandwidthVeryLow, .bandwidthLow,
         .qualityMedium, .qualityHigh, .qualityMax,
         .latencyLow, .latencyUltraLow]
    }

    public var index: Int { Self.available.firstIndex(of: self) ?? 0 }

    /// Python: `profile_name(profile)`
    public var name: String {
        switch self {
        case .bandwidthUltraLow: return "Ultra Low Bandwidth"
        case .bandwidthVeryLow:  return "Very Low Bandwidth"
        case .bandwidthLow:      return "Low Bandwidth"
        case .qualityMedium:     return "Medium Quality"
        case .qualityHigh:       return "High Quality"
        case .qualityMax:        return "Super High Quality"
        case .latencyLow:        return "Low Latency"
        case .latencyUltraLow:   return "Ultra Low Latency"
        }
    }

    /// Python: `profile_abbrevation(profile)` — note: typo in Python preserved
    public var abbreviation: String {
        switch self {
        case .bandwidthUltraLow: return "ULBW"
        case .bandwidthVeryLow:  return "VLBW"
        case .bandwidthLow:      return "LBW"
        case .qualityMedium:     return "MQ"
        case .qualityHigh:       return "HQ"
        case .qualityMax:        return "SHQ"
        case .latencyLow:        return "LL"
        case .latencyUltraLow:   return "ULL"
        }
    }

    /// Python: `get_frame_time(profile)` in ms
    public var frameTimeMs: Int {
        switch self {
        case .bandwidthUltraLow: return 400
        case .bandwidthVeryLow:  return 320
        case .bandwidthLow:      return 200
        case .qualityMedium:     return 60
        case .qualityHigh:       return 60
        case .qualityMax:        return 60
        case .latencyLow:        return 20
        case .latencyUltraLow:   return 10
        }
    }

    /// Python: `get_codec(profile)` — returns a fresh codec instance
    public var codec: any Codec {
        switch self {
        case .bandwidthUltraLow: return Codec2Codec(mode: .codec2_700c)
        case .bandwidthVeryLow:  return Codec2Codec(mode: .codec2_1600)
        case .bandwidthLow:      return Codec2Codec(mode: .codec2_3200)
        case .qualityMedium:     return OpusCodec(profile: .voiceMedium)
        case .qualityHigh:       return OpusCodec(profile: .voiceHigh)
        case .qualityMax:        return OpusCodec(profile: .voiceMax)
        case .latencyLow:        return OpusCodec(profile: .voiceMedium)
        case .latencyUltraLow:   return OpusCodec(profile: .voiceMedium)
        }
    }

    /// Python: `next_profile(profile)` — wraps around
    public static func next(after profile: TelephonyProfile) -> TelephonyProfile {
        let list = Self.available
        guard let idx = list.firstIndex(of: profile) else { return profile }
        return list[(idx + 1) % list.count]
    }
}

// MARK: - ActiveCall (internal link state)

/// Carries per-call state attached to an active RNS Link.
/// Python: attached as attributes directly on the `link` object.
public final class ActiveCall {
    public let link: Link
    public var isIncoming:   Bool = false
    public var isOutgoing:   Bool = false
    public var isTerminating: Bool = false
    public var ringTimeout:  Bool = false
    public var answered:     Bool = false
    public var profile: TelephonyProfile?
    public var packetizer: Packetizer?
    public var audioSource: LinkSource?
    public var filters: [any Filter] = []

    public init(link: Link) { self.link = link }

    public var remoteIdentity: Identity? { link.remoteIdentity }
    public var status: Link.Status { link.status }
    public var hash: Data? { link.linkID }
}

// MARK: - Telephone

/// Full telephony session manager — handles call establishment, audio pipelines,
/// signalling, gain, muting, and profile switching.
///
/// Python: `LXST.Primitives.Telephony.Telephone`
/// (Note: Python uses `Telephone`, our earlier stub was named `TelephonyCall`)
public final class Telephone: SignallingReceiver, SignallingHandler {

    // MARK: - Class constants

    /// Python: `Telephone.RING_TIME = 60`
    public static let ringTime: TimeInterval = 60
    /// Python: `Telephone.WAIT_TIME = 70`
    public static let waitTime: TimeInterval = 70
    /// Python: `Telephone.CONNECT_TIME = 5`
    public static let connectTime: TimeInterval = 5
    /// Python: `Telephone.DIAL_TONE_FREQUENCY = 382`
    public static let dialToneFrequency: Double = 382
    /// Python: `Telephone.DIAL_TONE_EASE_MS = 3.14159`
    public static let dialToneEaseMs: Double = 3.14159
    /// Python: `Telephone.JOB_INTERVAL = 5`
    public static let jobInterval: TimeInterval = 5
    /// Python: `Telephone.ANNOUNCE_INTERVAL_MIN = 60*5`
    public static let announceIntervalMin: TimeInterval = 300
    /// Python: `Telephone.ANNOUNCE_INTERVAL = 60*60*3`
    public static let announceInterval: TimeInterval = 10800
    /// Python: `Telephone.ALLOW_ALL = 0xFF`
    public static let allowAll: UInt8 = 0xFF
    /// Python: `Telephone.ALLOW_NONE = 0xFE`
    public static let allowNone: UInt8 = 0xFE

    // MARK: - State

    public let identity:  Identity
    public let transport: Transport
    public private(set) var destination: Destination?

    /// Current signalling state. Python: `call_status`
    public private(set) var callStatus: SignallingStatus = .available

    /// The active call link wrapper (nil when idle). Python: `active_call`
    public private(set) var activeCall: ActiveCall?

    /// Incoming links that have established but whose caller has not yet
    /// identified. They sit in AVAILABLE state until the remote identifies (or
    /// the link closes). Mirrors Python's `self.links` dict — an incoming link
    /// is only promoted to `activeCall` once the caller is identified and
    /// allowed. Keyed by link id.
    private var pendingIncomingLinks: [Data: Link] = [:]

    /// Who is allowed to call. Python: `allowed`
    public private(set) var allowed: AllowedCallers = .allowAll

    /// Explicitly blocked callers (identity hash list). Python: `blocked`
    public var blocked: [Data]? = nil

    /// Announce interval in seconds. Python: `announce_interval`
    public private(set) var announceIntervalSetting: TimeInterval = Telephone.announceInterval

    /// Timestamp of last announce. Python: `last_announce`
    public private(set) var lastAnnounce: TimeInterval = 0

    /// External busy flag (set by app to mark phone as busy for non-call reasons).
    /// Python: `_external_busy`
    public private(set) var externalBusy: Bool = false

    // Gain
    public private(set) var receiveGain:  Float = 0.0
    public private(set) var transmitGain: Float = 0.0

    // Mute state (persists when no active call so they can be applied on answer)
    private var receiveIsMuted:  Bool = false
    private var transmitIsMuted: Bool = false

    // AGC
    public var useAGC: Bool = true

    // Audio device selection
    public var speakerDevice:    String? = nil
    public var microphoneDevice: String? = nil
    public var ringerDevice:     String? = nil

    /// Factory for the platform audio backend used by the call's capture
    /// (`LineSource`) and playback (`LineSink`). `Telephone` itself is
    /// platform-agnostic; a host app injects this to wire real mic/speaker I/O
    /// (e.g. `{ AVAudioEngineBackend() }`). Each call returns a fresh instance
    /// because a backend owns a single engine, and capture + playback run on
    /// separate ones. When `nil`, the call still completes signalling but moves
    /// no audio (used by tests).
    public var makeAudioBackend: (() -> any AudioBackend)?

    // Ring/busy tone settings
    public var ringtone: URL? = nil
    public var busyToneSeconds: Double = 4.25
    public var lowLatencyOutput: Bool = false

    // Audio pipelines (internal)
    private var receiveMixer:     Mixer?
    private var transmitMixer:    Mixer?
    private var audioInput:       LineSource?
    private var audioOutput:      LineSink?
    private var dialTone:         ToneSource?
    private var receivePipeline:  Pipeline?
    private var transmitPipeline: Pipeline?

    private var transmitCodec: (any Codec)?
    private var receiveCodec:  (any Codec)?
    private var targetFrameTimeMs: Double = 60

    // Thread safety
    private let callHandlerLock          = NSLock()
    private let pipelineLock             = NSLock()
    private let callerPipelineOpenLock   = NSLock()
    private let ringerLock               = NSLock()

    // Callbacks
    private var ringingCallback:     ((Identity?) -> Void)?
    private var establishedCallback: ((Identity?) -> Void)?
    private var endedCallback:       ((Identity?) -> Void)?
    private var busyCallback:        ((Identity?) -> Void)?
    private var rejectedCallback:    ((Identity?) -> Void)?

    // MARK: - Init

    /// Python: `Telephone.__init__(identity, ring_time, wait_time, auto_answer, allowed, receive_gain, transmit_gain)`
    public init(identity: Identity,
                transport: Transport,
                ringTime: TimeInterval = Telephone.ringTime,
                waitTime: TimeInterval = Telephone.waitTime,
                autoAnswer: Bool? = nil,
                allowed: AllowedCallers = .allowAll,
                receiveGain: Float = 0.0,
                transmitGain: Float = 0.0) {
        self.identity      = identity
        self.transport     = transport
        self.allowed       = allowed
        self.receiveGain   = receiveGain
        self.transmitGain  = transmitGain
        super.init()

        // Create local delivery destination
        if let dest = try? Destination(identity: identity,
                                       direction: .in, kind: .single,
                                       appName: APP_NAME,
                                       aspects: [LXST_TELEPHONY_PRIMITIVE]) {
            dest.setProofStrategy(.proveNone)
            dest.onLinkEstablished = { [weak self] link in
                self?.incomingLinkEstablished(link)
            }
            self.destination = dest
            transport.register(destination: dest)
        }
    }

    deinit {
        hangup()
        if let d = destination { transport.deregister(destination: d) }
    }

    // MARK: - Announce

    /// Announce this telephone's presence on the network.
    /// Python: `Telephone.announce(attached_interface=None)`
    public func announce(attachedInterface: (any Interface)? = nil) {
        guard let dest = destination else { return }
        if let iface = attachedInterface {
            try? dest.announce(attachedInterface: iface)
        } else {
            try? dest.announce()
        }
        lastAnnounce = Date().timeIntervalSince1970
    }

    // MARK: - Configuration

    /// Python: `set_allowed(allowed)` — AllowedCallers enum or list
    public func setAllowed(_ allowed: AllowedCallers) { self.allowed = allowed }

    /// Python: `set_blocked(blocked)`
    public func setBlocked(_ blocked: [Data]?) { self.blocked = blocked }

    /// Python: `set_announce_interval(announce_interval)`
    public func setAnnounceInterval(_ interval: TimeInterval) {
        announceIntervalSetting = max(interval, Telephone.announceIntervalMin)
    }

    /// Python: `set_busy(busy)`
    public func setExternalBusy(_ busy: Bool) { externalBusy = busy }

    // MARK: - Callbacks

    /// Python: `set_ringing_callback(callback)`
    public func setRingingCallback(_ cb: @escaping (Identity?) -> Void) {
        ringingCallback = cb
    }
    /// Python: `set_established_callback(callback)`
    public func setEstablishedCallback(_ cb: @escaping (Identity?) -> Void) {
        establishedCallback = cb
    }
    /// Python: `set_ended_callback(callback)`
    public func setEndedCallback(_ cb: @escaping (Identity?) -> Void) {
        endedCallback = cb
    }
    /// Python: `set_busy_callback(callback)`
    public func setBusyCallback(_ cb: @escaping (Identity?) -> Void) {
        busyCallback = cb
    }
    /// Python: `set_rejected_callback(callback)`
    public func setRejectedCallback(_ cb: @escaping (Identity?) -> Void) {
        rejectedCallback = cb
    }

    // MARK: - Gain

    /// Python: `set_receive_gain(gain=0.0)`
    public func setReceiveGain(_ gain: Float = 0.0) {
        receiveGain = gain
        receiveMixer?.setGain(gain)
    }

    /// Python: `set_transmit_gain(gain=0.0)`
    public func setTransmitGain(_ gain: Float = 0.0) {
        transmitGain = gain
        transmitMixer?.setGain(gain)
    }

    // MARK: - Mute

    /// Python: `mute_receive(mute=True)`
    public func muteReceive(_ mute: Bool = true) {
        receiveIsMuted = mute
        receiveMixer?.mute(mute)
    }
    /// Python: `unmute_receive(unmute=True)`
    public func unmuteReceive(_ unmute: Bool = true) {
        receiveIsMuted = !unmute
        receiveMixer?.unmute(unmute)
    }
    /// Python: `mute_transmit(mute=True)`
    public func muteTransmit(_ mute: Bool = true) {
        transmitIsMuted = mute
        transmitMixer?.mute(mute)
    }
    /// Python: `unmute_transmit(unmute=True)`
    public func unmuteTransmit(_ unmute: Bool = true) {
        transmitIsMuted = !unmute
        transmitMixer?.unmute(unmute)
    }

    // MARK: - Computed properties

    /// Python: `busy` property
    public var busy: Bool {
        callStatus != .available || externalBusy
    }

    /// Python: `active_profile` property
    public var activeProfile: TelephonyProfile? { activeCall?.profile }

    /// Python: `receive_muted` property
    public var receiveMuted: Bool {
        receiveMixer?.muted ?? receiveIsMuted
    }

    /// Python: `transmit_muted` property
    public var transmitMuted: Bool {
        transmitMixer?.muted ?? transmitIsMuted
    }

    // MARK: - Signalling

    /// Send a raw signal value on `link` and update `callStatus` if it's an
    /// auto-status code, then transmit it over the link.
    ///
    /// Python: `Telephone.signal(signal, link)` →
    /// ```
    /// if signal in Signalling.AUTO_STATUS_CODES: self.call_status = signal
    /// super().signal(signal, link)
    /// ```
    /// The value is an `Int` (not `UInt8`) so the composite
    /// `PREFERRED_PROFILE + profile` (e.g. `0x13F`) round-trips intact.
    public func sendSignal(_ signal: Int, on link: Link) {
        if signal >= 0, signal <= 0xFF,
           let status = SignallingStatus(rawValue: UInt8(signal)),
           SignallingStatus.autoStatusCodes.contains(status) {
            callStatus = status
        }
        // Inherited SignallingReceiver.signal — encodes {FIELD_SIGNALLING:[signal]}
        // and sends it over the link (encrypted with the link key, routed by transport).
        self.signal(signal, to: link)
    }

    /// Convenience overload for sending a `SignallingStatus` code.
    public func sendSignal(_ status: SignallingStatus, on link: Link) {
        sendSignal(Int(status.rawValue), on: link)
    }

    // MARK: - Outgoing call

    /// Initiate an outgoing call to `identity`.
    /// Python: `Telephone.call(identity, profile=None)`
    public func call(identity: Identity, profile: TelephonyProfile? = nil) {
        callHandlerLock.lock()
        defer { callHandlerLock.unlock() }
        guard activeCall == nil else { return }

        callStatus = .calling
        let callDest = try? Destination(identity: identity,
                                        direction: .out, kind: .single,
                                        appName: APP_NAME,
                                        aspects: [LXST_TELEPHONY_PRIMITIVE])
        guard let dest = callDest else { return }

        let link = try? Link.initiate(destination: dest, transport: transport)
        guard let link else { callStatus = .available; return }

        let call = ActiveCall(link: link)
        call.isIncoming    = false
        call.isOutgoing    = true
        call.isTerminating = false
        call.profile       = profile ?? TelephonyProfile.defaultProfile
        activeCall = call

        link.onEstablished = { [weak self] l in
            self?.outgoingLinkEstablished(l)
        }
        link.onClosed = { [weak self] l in
            if self?.activeCall?.link === l { self?.hangup() }
        }

        // Outgoing call timeout: if the call hasn't reached ESTABLISHED within
        // `waitTime`, give up. Mirrors Python's `__timeout_outgoing_call_at` /
        // `__timeout_outgoing_establishment_at` (Swift previously had none, so a
        // call to an unreachable/unanswering peer hung in CALLING forever).
        let pendingCall = call
        DispatchQueue.global().asyncAfter(deadline: .now() + Telephone.waitTime) { [weak self] in
            guard let self, self.activeCall === pendingCall,
                  self.callStatus.rawValue < SignallingStatus.established.rawValue else { return }
            self.hangup()
        }
    }

    // MARK: - Answer incoming call

    /// Answer an active incoming call from `identity`.
    /// Python: `Telephone.answer(identity)`
    @discardableResult
    public func answer(identity: Identity) -> Bool {
        callHandlerLock.lock()
        defer { callHandlerLock.unlock() }
        guard let call = activeCall else { return false }
        guard call.remoteIdentity?.hash == identity.hash else { return false }

        call.answered = true
        openPipelines(for: identity)
        startPipelines()
        establishedCallback?(identity)
        return true
    }

    // MARK: - Hangup

    /// End the current call. Python: `Telephone.hangup(reason=None)`
    public func hangup(reason: SignallingStatus? = nil) {
        callHandlerLock.lock()
        let call = activeCall
        activeCall = nil
        let remote = call?.remoteIdentity
        let wasRingingIncoming = (call?.isIncoming ?? false) && callStatus == .ringing
        let ringTimedOut = call?.ringTimeout ?? false
        callHandlerLock.unlock()

        // Declining (or losing) an unanswered, still-ringing incoming call
        // tells the caller we rejected it. Mirrors Python `hangup`'s
        // STATUS_REJECTED signal. Skipped on ring-timeout (the caller already
        // sees no answer) and when the link is already gone.
        if let call, wasRingingIncoming, !ringTimedOut, call.link.status == .active {
            sendSignal(.rejected, on: call.link)
        }

        if let link = call?.link, link.status == .active {
            try? link.teardown()
        }

        stopPipelines()
        pipelineLock.lock()
        receiveMixer      = nil
        transmitMixer     = nil
        receivePipeline   = nil
        transmitPipeline  = nil
        audioOutput       = nil
        dialTone          = nil
        pipelineLock.unlock()

        callStatus       = .available
        receiveIsMuted   = false
        transmitIsMuted  = false

        switch reason {
        case .busy:
            if let cb = busyCallback     { cb(remote) }
            else                         { endedCallback?(remote) }
        case .rejected:
            if let cb = rejectedCallback { cb(remote) }
            else                         { endedCallback?(remote) }
        default:
            endedCallback?(remote)
        }
    }

    // MARK: - Profile switching

    /// Switch codec profile mid-call.
    /// Python: `Telephone.switch_profile(profile, from_signalling=False)`
    public func switchProfile(_ profile: TelephonyProfile, fromSignalling: Bool = false) {
        guard let call = activeCall, callStatus == .established else { return }
        guard call.profile != profile else { return }
        call.profile = profile
        transmitCodec = profile.codec
        targetFrameTimeMs = Double(profile.frameTimeMs)
        if !fromSignalling, let link = activeCall?.link {
            // Python: self.signal(Signalling.PREFERRED_PROFILE + self.active_call.profile, ...)
            let composite = Int(SIGNALLING_PREFERRED_PROFILE) + Int(profile.rawValue)
            sendSignal(composite, on: link)
        }
        reconfigureTransmitPipeline()
    }

    // MARK: - SignallingReceiver override

    /// Handle incoming signalling packets from the active call link.
    /// Python: `Telephone.signalling_received(signals, source)`
    override public func signallingReceived(_ signals: [Int], from source: (any Source)?) {
        guard let call = activeCall else { return }

        for signal in signals {
            // Incoming, not-yet-answered calls ignore status codes but still accept
            // profile-preference signals (>= PREFERRED_PROFILE), so the preferred
            // codec is recorded while ringing. Python: first guard of signalling_received.
            if call.isIncoming, !call.answered, signal < Int(SIGNALLING_PREFERRED_PROFILE) {
                return
            }

            // Profile-preference composite signal (Python: signal >= PREFERRED_PROFILE).
            // PREFERRED_PROFILE (0xFF) + profile (0x10..0x80) exceeds a single byte.
            if signal >= Int(SIGNALLING_PREFERRED_PROFILE) {
                let profileRaw = signal - Int(SIGNALLING_PREFERRED_PROFILE)
                if profileRaw >= 0, profileRaw <= 0xFF,
                   let profile = TelephonyProfile(rawValue: UInt8(profileRaw)) {
                    if callStatus == .established {
                        switchProfile(profile, fromSignalling: true)
                    } else {
                        selectCallProfile(profile)
                    }
                }
                continue
            }

            guard signal >= 0, signal <= 0xFF,
                  let status = SignallingStatus(rawValue: UInt8(signal)) else { continue }

            switch status {
            case .busy:
                call.isTerminating = true
                hangup(reason: .busy)

            case .rejected:
                hangup(reason: .rejected)

            case .available:
                callStatus = .available
                try? call.link.identify(as: identity)

            case .ringing:
                callStatus = .ringing
                prepareDiallingPipelines()
                if call.isOutgoing {
                    // Python: self.signal(Signalling.PREFERRED_PROFILE + self.active_call.profile, ...)
                    let composite = Int(SIGNALLING_PREFERRED_PROFILE) +
                                    Int((call.profile ?? .qualityMedium).rawValue)
                    sendSignal(composite, on: call.link)
                }

            case .connecting:
                callStatus = .connecting
                callerPipelineOpenLock.lock()
                resetDiallingPipelines()
                openPipelines(for: call.remoteIdentity ?? identity)
                callerPipelineOpenLock.unlock()

            case .established:
                if call.isOutgoing {
                    callerPipelineOpenLock.lock()
                    startPipelines()
                    disableDialTone()
                    callerPipelineOpenLock.unlock()
                    callStatus = .established
                    establishedCallback?(call.remoteIdentity)
                }

            case .calling:
                callStatus = .calling
            }
        }
    }

    // MARK: - Incoming link

    /// An incoming call link has established. Mirrors Python
    /// `__incoming_link_established`: we do NOT promote it to `activeCall` and
    /// do NOT ring yet — we register a remote-identified callback, park the link
    /// in `pendingIncomingLinks`, and signal AVAILABLE. The caller responds to
    /// AVAILABLE by identifying, which fires `callerIdentified`, where the
    /// allow-check and ringing happen.
    private func incomingLinkEstablished(_ link: Link) {
        callHandlerLock.lock()
        let lineBusy = (activeCall != nil) || busy
        if !lineBusy, let id = link.linkID { pendingIncomingLinks[id] = link }
        callHandlerLock.unlock()

        guard !lineBusy else {
            sendSignal(.busy, on: link)
            link.onClosed = nil
            try? link.teardown()
            return
        }

        link.onClosed = { [weak self] l in self?.incomingLinkClosed(l) }
        link.setRemoteIdentifiedCallback { [weak self] l, callerIdentity in
            self?.callerIdentified(l, identity: callerIdentity)
        }
        sendSignal(.available, on: link)
    }

    /// The caller on an incoming link has identified. Mirrors Python
    /// `__caller_identified`: re-check busy/allowed (signalling BUSY + tearing
    /// down if not), otherwise promote the link to `activeCall`, ring, fire the
    /// ringing callback, and arm the ring timeout.
    private func callerIdentified(_ link: Link, identity callerIdentity: Identity) {
        callHandlerLock.lock()
        if let id = link.linkID { pendingIncomingLinks[id] = nil }
        let admit = (activeCall == nil) && !busy && isAllowed(callerIdentity)
        let call: ActiveCall?
        if admit {
            let c = ActiveCall(link: link)
            c.isIncoming    = true
            c.isOutgoing    = false
            c.isTerminating = false
            c.profile       = TelephonyProfile.defaultProfile
            activeCall = c
            call = c
        } else {
            call = nil
        }
        callHandlerLock.unlock()

        guard let call else {
            sendSignal(.busy, on: link)
            try? link.teardown()
            return
        }

        link.onClosed = { [weak self] l in
            if self?.activeCall?.link === l, !(self?.activeCall?.isTerminating ?? false) {
                self?.hangup()
            }
        }
        handleSignallingFrom(source: link)
        prepareDiallingPipelines()
        sendSignal(.ringing, on: link)
        ringingCallback?(callerIdentity)

        DispatchQueue.global().asyncAfter(deadline: .now() + Telephone.ringTime) { [weak self] in
            guard let self, self.activeCall?.link === link,
                  self.activeCall?.answered == false else { return }
            call.ringTimeout = true
            self.hangup()
        }
    }

    /// A parked-or-active incoming link closed before/while ringing.
    private func incomingLinkClosed(_ link: Link) {
        callHandlerLock.lock()
        if let id = link.linkID { pendingIncomingLinks[id] = nil }
        let isActive    = activeCall?.link === link
        let terminating = activeCall?.isTerminating ?? false
        callHandlerLock.unlock()
        if isActive, !terminating { hangup() }
    }

    /// Whether `identity` is permitted to call. Mirrors Python `__is_allowed`.
    private func isAllowed(_ identity: Identity) -> Bool {
        if let blocked, blocked.contains(identity.hash) { return false }
        switch allowed {
        case .allowAll:  return true
        case .allowNone: return false
        }
    }

    private func outgoingLinkEstablished(_ link: Link) {
        link.onClosed = { [weak self] l in
            if self?.activeCall?.link === l { self?.hangup() }
        }
        handleSignallingFrom(source: link)
    }

    // MARK: - Pipeline management

    private func selectCallProfile(_ profile: TelephonyProfile) {
        activeCall?.profile = profile
        transmitCodec = profile.codec
        receiveCodec  = NullCodec()
        targetFrameTimeMs = Double(profile.frameTimeMs)
    }

    private func prepareDiallingPipelines() {
        selectCallProfile(activeCall?.profile ?? .qualityMedium)
        if audioOutput    == nil { audioOutput    = LineSink(device: speakerDevice, backend: makeAudioBackend?()) }
        if receiveMixer   == nil { receiveMixer   = Mixer(targetFrameMs: targetFrameTimeMs, gain: receiveGain) }
        if dialTone       == nil { dialTone       = ToneSource(frequency: Telephone.dialToneFrequency,
                                                                gain: 0,
                                                                easeTimeMs: Telephone.dialToneEaseMs,
                                                                targetFrameMs: targetFrameTimeMs,
                                                                codec: NullCodec(),
                                                                sink: receiveMixer) }
        if receivePipeline == nil {
            receivePipeline = try? Pipeline(source: receiveMixer!, codec: NullCodec(), sink: audioOutput!)
        }
    }

    private func resetDiallingPipelines() {
        pipelineLock.lock()
        audioOutput?.stop()
        dialTone?.stop()
        receivePipeline?.stop()
        receiveMixer?.stop()
        audioOutput    = nil
        dialTone       = nil
        receivePipeline = nil
        receiveMixer   = nil
        pipelineLock.unlock()
        prepareDiallingPipelines()
    }

    private func openPipelines(for identity: Identity) {
        pipelineLock.lock()
        defer { pipelineLock.unlock() }

        let filters: [any Filter] = useAGC
            ? [BandPass(lowCut: 250, highCut: 8500), AGC(targetLevel: -15)]
            : [BandPass(lowCut: 250, highCut: 8500)]

        activeCall?.filters = filters
        prepareDiallingPipelines()

        guard let call = activeCall,
              let rMixer = receiveMixer,
              let output = audioOutput else { return }

        let pkt = Packetizer(destination: call.link, onFailure: { [weak self] in
            self?.hangup()
        })
        call.packetizer = pkt

        let tMixer = Mixer(targetFrameMs: targetFrameTimeMs, gain: transmitGain)
        transmitMixer = tMixer

        let input = LineSource(device: microphoneDevice,
                               targetFrameMs: targetFrameTimeMs,
                               codec: RawCodec(),
                               sink: tMixer,
                               filters: filters,
                               easeIn: 0.225,
                               skip: 0.075,
                               backend: makeAudioBackend?())
        audioInput = input

        if let txCodec = transmitCodec {
            transmitPipeline = try? Pipeline(source: tMixer, codec: txCodec, sink: pkt)
        }

        let audioSrc = LinkSource(link: call.link, signallingProxy: self, sink: rMixer)
        call.audioSource = audioSrc
        rMixer.setSourceMaxFrames(2, for: audioSrc)

        if call.isIncoming {
            sendSignal(.connecting, on: call.link)
        }
        sendSignal(.established, on: call.link)
        _ = output
    }

    private func startPipelines() {
        pipelineLock.lock()
        defer { pipelineLock.unlock() }
        receiveMixer?.start()
        transmitMixer?.start()
        audioInput?.start()
        transmitPipeline?.start()
        if receivePipeline?.running == false { receivePipeline?.start() }
    }

    private func stopPipelines() {
        pipelineLock.lock()
        defer { pipelineLock.unlock() }
        receiveMixer?.stop()
        transmitMixer?.stop()
        audioInput?.stop()
        receivePipeline?.stop()
        transmitPipeline?.stop()
    }

    private func reconfigureTransmitPipeline() {
        guard callStatus == .established else { return }
        audioInput?.stop()
        transmitMixer?.stop()
        transmitPipeline?.stop()

        let tMixer = Mixer(targetFrameMs: targetFrameTimeMs, gain: transmitGain)
        tMixer.mute(transmitIsMuted)
        transmitMixer = tMixer

        guard let call = activeCall else { return }
        let input = LineSource(device: microphoneDevice,
                               targetFrameMs: targetFrameTimeMs,
                               codec: RawCodec(),
                               sink: tMixer,
                               filters: call.filters,
                               skip: 0.075,
                               backend: makeAudioBackend?())
        audioInput = input

        if let txCodec = transmitCodec, let pkt = call.packetizer {
            transmitPipeline = try? Pipeline(source: tMixer, codec: txCodec, sink: pkt)
        }

        tMixer.start()
        input.start()
        transmitPipeline?.start()
    }

    private func enableDialTone() {
        receiveMixer?.start()
        dialTone?.gain = 0.04
        if dialTone?.shouldRun == false { dialTone?.start() }
    }

    private func disableDialTone() {
        dialTone?.stop()
    }
}

// MARK: - Test helpers (internal; allow unit tests to fire callbacks without real links)

extension Telephone {
    /// Set callStatus directly — for testing only.
    public func testSetCallStatus(_ status: SignallingStatus) {
        callStatus = status
    }

    /// Fire the ringing callback — for testing only.
    public func testFireRingingCallback(identity: Identity?) {
        ringingCallback?(identity)
    }

    /// Fire the established callback — for testing only.
    public func testFireEstablishedCallback(identity: Identity?) {
        establishedCallback?(identity)
    }

    /// Fire the ended callback — for testing only.
    public func testFireEndedCallback(identity: Identity?) {
        endedCallback?(identity)
    }

    /// Fire the busy callback — for testing only.
    public func testFireBusyCallback(identity: Identity?) {
        busyCallback?(identity)
    }

    /// Fire the rejected callback — for testing only.
    public func testFireRejectedCallback(identity: Identity?) {
        rejectedCallback?(identity)
    }

    /// Send a signal without a real link — for testing state transitions only.
    public func testSignal(_ status: SignallingStatus) {
        if SignallingStatus.autoStatusCodes.contains(status) {
            callStatus = status
        }
    }
}
