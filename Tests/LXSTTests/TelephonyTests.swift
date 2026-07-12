import XCTest
@testable import LXST

/// Tests for the full Telephone session manager and Signalling constants.
///
/// Python reference: LXST.Primitives.Telephony
///   - Signalling class (status codes, PREFERRED_PROFILE, AUTO_STATUS_CODES)
///   - Telephone class (constants, lifecycle, audio, callbacks, signalling)
final class TelephonyTests: XCTestCase {

    // MARK: - Primitive name

    func testPrimitiveName() {
        XCTAssertEqual(LXST_TELEPHONY_PRIMITIVE, "telephony")
    }

    // MARK: - Signalling status codes (Python: Signalling.STATUS_*)

    func testSignallingStatusBusy() {
        XCTAssertEqual(SignallingStatus.busy.rawValue,        0x00) // STATUS_BUSY
    }
    func testSignallingStatusRejected() {
        XCTAssertEqual(SignallingStatus.rejected.rawValue,    0x01) // STATUS_REJECTED
    }
    func testSignallingStatusCalling() {
        XCTAssertEqual(SignallingStatus.calling.rawValue,     0x02) // STATUS_CALLING
    }
    func testSignallingStatusAvailable() {
        XCTAssertEqual(SignallingStatus.available.rawValue,   0x03) // STATUS_AVAILABLE
    }
    func testSignallingStatusRinging() {
        XCTAssertEqual(SignallingStatus.ringing.rawValue,     0x04) // STATUS_RINGING
    }
    func testSignallingStatusConnecting() {
        XCTAssertEqual(SignallingStatus.connecting.rawValue,  0x05) // STATUS_CONNECTING
    }
    func testSignallingStatusEstablished() {
        XCTAssertEqual(SignallingStatus.established.rawValue, 0x06) // STATUS_ESTABLISHED
    }

    // MARK: - PREFERRED_PROFILE marker (Python: Signalling.PREFERRED_PROFILE = 0xFF)

    func testSignallingPreferredProfile() {
        XCTAssertEqual(SIGNALLING_PREFERRED_PROFILE, 0xFF,
                       "PREFERRED_PROFILE must be 0xFF")
    }

    // MARK: - AUTO_STATUS_CODES

    func testAutoStatusCodesContainExpectedStatuses() {
        // Python: AUTO_STATUS_CODES = [CALLING, AVAILABLE, RINGING, CONNECTING, ESTABLISHED]
        let auto: Set<SignallingStatus> = [.calling, .available, .ringing, .connecting, .established]
        XCTAssertEqual(Set(SignallingStatus.autoStatusCodes), auto)
    }

    func testAutoStatusCodesDoNotContainBusyOrRejected() {
        XCTAssertFalse(SignallingStatus.autoStatusCodes.contains(.busy))
        XCTAssertFalse(SignallingStatus.autoStatusCodes.contains(.rejected))
    }

    // MARK: - Telephone class constants

    func testTelephoneRingTime() {
        XCTAssertEqual(Telephone.ringTime, 60, "RING_TIME must be 60 seconds")
    }
    func testTelephoneWaitTime() {
        XCTAssertEqual(Telephone.waitTime, 70, "WAIT_TIME must be 70 seconds")
    }
    func testTelephoneConnectTime() {
        XCTAssertEqual(Telephone.connectTime, 5, "CONNECT_TIME must be 5 seconds")
    }
    func testTelephoneDialToneFrequency() {
        XCTAssertEqual(Telephone.dialToneFrequency, 382.0, accuracy: 0.001,
                       "DIAL_TONE_FREQUENCY must be 382 Hz")
    }
    func testTelephoneDialToneEaseMs() {
        XCTAssertEqual(Telephone.dialToneEaseMs, 3.14159, accuracy: 0.00001,
                       "DIAL_TONE_EASE_MS must be 3.14159 ms")
    }
    func testTelephoneJobInterval() {
        XCTAssertEqual(Telephone.jobInterval, 5.0, "JOB_INTERVAL must be 5 seconds")
    }
    func testTelephoneAnnounceIntervalMin() {
        XCTAssertEqual(Telephone.announceIntervalMin, 300.0,
                       "ANNOUNCE_INTERVAL_MIN must be 300 s (60*5)")
    }
    func testTelephoneAnnounceInterval() {
        XCTAssertEqual(Telephone.announceInterval, 10800.0,
                       "ANNOUNCE_INTERVAL must be 10800 s (60*60*3)")
    }
    func testTelephoneAllowAll() {
        XCTAssertEqual(Telephone.allowAll, 0xFF, "ALLOW_ALL must be 0xFF")
    }
    func testTelephoneAllowNone() {
        XCTAssertEqual(Telephone.allowNone, 0xFE, "ALLOW_NONE must be 0xFE")
    }

    // MARK: - Telephone init / initial state

    func makePhone() -> Telephone {
        Telephone(identity: Identity(), transport: Transport())
    }

    func testTelephoneInitialCallStatusIsAvailable() {
        let phone = makePhone()
        XCTAssertEqual(phone.callStatus, .available,
                       "Initial call_status must be STATUS_AVAILABLE")
    }

    func testTelephoneInitialBusyIsFalse() {
        let phone = makePhone()
        XCTAssertFalse(phone.busy, "New Telephone must not be busy")
    }

    func testTelephoneInitialActiveCallIsNil() {
        let phone = makePhone()
        XCTAssertNil(phone.activeCall, "No active call on init")
    }

    // MARK: - Destination aspect (Python interop)

    /// The Telephone must serve the `lxst.telephony` destination — the same
    /// app_name + primitive (`APP_NAME="lxst"`, `PRIMITIVE_NAME="telephony"`) a
    /// Python `rnphone`/LXST node uses — or cross-implementation calls can never
    /// reach it. Pins the aspect against a manually-built destination hash.
    func testTelephoneServesLxstTelephonyDestination() throws {
        let identity = Identity()
        let phone = Telephone(identity: identity, transport: Transport())
        let expected = try Destination(identity: identity, direction: .in, kind: .single,
                                       appName: "lxst", aspects: ["telephony"])
        XCTAssertEqual(phone.destination?.hash, expected.hash,
                       "Telephone must serve lxst.telephony for Python LXST interop")
    }

    func testTelephoneDefaultReceiveGainIsZero() {
        let phone = makePhone()
        XCTAssertEqual(phone.receiveGain, 0.0, accuracy: 0.001)
    }

    func testTelephoneDefaultTransmitGainIsZero() {
        let phone = makePhone()
        XCTAssertEqual(phone.transmitGain, 0.0, accuracy: 0.001)
    }

    // MARK: - setAllowed / setBlocked

    func testSetAllowedAllowAll() {
        let phone = makePhone()
        phone.setAllowed(.allowAll)
        XCTAssertEqual(phone.allowed, .allowAll)
    }

    func testSetAllowedAllowNone() {
        let phone = makePhone()
        phone.setAllowed(.allowNone)
        XCTAssertEqual(phone.allowed, .allowNone)
    }

    // MARK: - setAnnounceInterval

    func testSetAnnounceIntervalClampsToMin() {
        let phone = makePhone()
        phone.setAnnounceInterval(10)  // below ANNOUNCE_INTERVAL_MIN=300
        XCTAssertGreaterThanOrEqual(phone.announceIntervalSetting, Telephone.announceIntervalMin,
                                    "Announce interval must be clamped to ANNOUNCE_INTERVAL_MIN")
    }

    func testSetAnnounceIntervalAcceptsValidValue() {
        let phone = makePhone()
        phone.setAnnounceInterval(600)
        XCTAssertEqual(phone.announceIntervalSetting, 600)
    }

    // MARK: - Callbacks

    func testSetRingingCallback() {
        let phone = makePhone()
        var fired = false
        phone.setRingingCallback { _ in fired = true }
        phone.testFireRingingCallback(identity: Identity())
        XCTAssertTrue(fired, "Ringing callback must be called")
    }

    func testSetEstablishedCallback() {
        let phone = makePhone()
        var fired = false
        phone.setEstablishedCallback { _ in fired = true }
        phone.testFireEstablishedCallback(identity: Identity())
        XCTAssertTrue(fired, "Established callback must be called")
    }

    func testSetEndedCallback() {
        let phone = makePhone()
        var fired = false
        phone.setEndedCallback { _ in fired = true }
        phone.testFireEndedCallback(identity: nil)
        XCTAssertTrue(fired, "Ended callback must be called")
    }

    func testSetBusyCallback() {
        let phone = makePhone()
        var fired = false
        phone.setBusyCallback { _ in fired = true }
        phone.testFireBusyCallback(identity: nil)
        XCTAssertTrue(fired, "Busy callback must be called")
    }

    func testSetRejectedCallback() {
        let phone = makePhone()
        var fired = false
        phone.setRejectedCallback { _ in fired = true }
        phone.testFireRejectedCallback(identity: nil)
        XCTAssertTrue(fired, "Rejected callback must be called")
    }

    // MARK: - Gain

    func testSetReceiveGain() {
        let phone = makePhone()
        phone.setReceiveGain(6.0)
        XCTAssertEqual(phone.receiveGain, 6.0, accuracy: 0.001)
    }

    func testSetTransmitGain() {
        let phone = makePhone()
        phone.setTransmitGain(-3.0)
        XCTAssertEqual(phone.transmitGain, -3.0, accuracy: 0.001)
    }

    // MARK: - Mute/unmute

    func testMuteReceiveSetsMuted() {
        let phone = makePhone()
        phone.muteReceive(true)
        XCTAssertTrue(phone.receiveMuted, "muteReceive(true) must set receiveMuted")
    }

    func testUnmuteReceiveClearsMuted() {
        let phone = makePhone()
        phone.muteReceive(true)
        phone.unmuteReceive(true)
        XCTAssertFalse(phone.receiveMuted, "unmuteReceive must clear receiveMuted")
    }

    func testMuteTransmitSetsMuted() {
        let phone = makePhone()
        phone.muteTransmit(true)
        XCTAssertTrue(phone.transmitMuted)
    }

    func testUnmuteTransmitClearsMuted() {
        let phone = makePhone()
        phone.muteTransmit(true)
        phone.unmuteTransmit(true)
        XCTAssertFalse(phone.transmitMuted)
    }

    // MARK: - busy / setExternalBusy

    func testSetExternalBusyMakesBusy() {
        let phone = makePhone()
        XCTAssertFalse(phone.busy)
        phone.setExternalBusy(true)
        XCTAssertTrue(phone.busy, "setExternalBusy(true) must make busy return true")
    }

    func testCallStatusNotAvailableMakesBusy() {
        let phone = makePhone()
        phone.testSetCallStatus(.calling)
        XCTAssertTrue(phone.busy,
                      "busy must be true when callStatus != .available")
    }

    // MARK: - hangup sets callStatus to available

    func testHangupSetsStatusAvailable() {
        let phone = makePhone()
        phone.testSetCallStatus(.established)
        phone.hangup()
        XCTAssertEqual(phone.callStatus, .available,
                       "hangup() must reset call_status to STATUS_AVAILABLE")
    }

    func testHangupNilsActiveCall() {
        let phone = makePhone()
        phone.testSetCallStatus(.ringing)
        phone.hangup()
        XCTAssertNil(phone.activeCall, "hangup() must clear active_call")
    }

    func testHangupFiresEndedCallback() {
        let phone = makePhone()
        var ended = false
        phone.setEndedCallback { _ in ended = true }
        phone.testSetCallStatus(.established)
        phone.hangup()
        XCTAssertTrue(ended, "hangup() with no reason must fire ended callback")
    }

    func testHangupBusyFiresBusyCallback() {
        let phone = makePhone()
        var busyCalled = false; var endedCalled = false
        phone.setBusyCallback { _ in busyCalled = true }
        phone.setEndedCallback { _ in endedCalled = true }
        phone.testSetCallStatus(.established)
        phone.hangup(reason: .busy)
        XCTAssertTrue(busyCalled, "hangup(reason:.busy) must fire busy callback")
        XCTAssertFalse(endedCalled, "hangup(reason:.busy) must NOT fire ended callback if busy callback set")
    }

    func testHangupRejectedFiresRejectedCallback() {
        let phone = makePhone()
        var rejectedCalled = false
        phone.setRejectedCallback { _ in rejectedCalled = true }
        phone.testSetCallStatus(.ringing)
        phone.hangup(reason: .rejected)
        XCTAssertTrue(rejectedCalled, "hangup(reason:.rejected) must fire rejected callback")
    }

    // MARK: - signal() updates callStatus for AUTO_STATUS_CODES

    func testSignalAutoStatusCodeUpdatesCallStatus() {
        let phone = makePhone()
        for status in SignallingStatus.autoStatusCodes {
            phone.testSetCallStatus(.available)
            phone.testSignal(status)
            XCTAssertEqual(phone.callStatus, status,
                           "signal(\(status)) must update callStatus")
        }
    }

    func testSignalBusyDoesNotUpdateCallStatus() {
        let phone = makePhone()
        phone.testSetCallStatus(.available)
        phone.testSignal(.busy)
        XCTAssertEqual(phone.callStatus, .available,
                       "signal(.busy) must NOT update callStatus (not in AUTO_STATUS_CODES)")
    }

    // MARK: - TelephonyProfile raw values (Python: Profiles raw values)

    func testProfileRawValues() {
        XCTAssertEqual(TelephonyProfile.bandwidthUltraLow.rawValue, 0x10)
        XCTAssertEqual(TelephonyProfile.bandwidthVeryLow.rawValue,  0x20)
        XCTAssertEqual(TelephonyProfile.bandwidthLow.rawValue,      0x30)
        XCTAssertEqual(TelephonyProfile.qualityMedium.rawValue,     0x40)
        XCTAssertEqual(TelephonyProfile.qualityHigh.rawValue,       0x50)
        XCTAssertEqual(TelephonyProfile.qualityMax.rawValue,        0x60)
        XCTAssertEqual(TelephonyProfile.latencyUltraLow.rawValue,   0x70)
        XCTAssertEqual(TelephonyProfile.latencyLow.rawValue,        0x80)
    }

    func testDefaultProfile() {
        XCTAssertEqual(TelephonyProfile.defaultProfile, .qualityMedium)
    }

    func testBandwidthProfilesUseCodec2() {
        XCTAssertTrue(TelephonyProfile.bandwidthUltraLow.codec is Codec2Codec)
        XCTAssertTrue(TelephonyProfile.bandwidthVeryLow.codec  is Codec2Codec)
        XCTAssertTrue(TelephonyProfile.bandwidthLow.codec      is Codec2Codec)
    }

    func testQualityAndLatencyProfilesUseOpus() {
        XCTAssertTrue(TelephonyProfile.qualityMedium.codec   is OpusCodec)
        XCTAssertTrue(TelephonyProfile.qualityHigh.codec     is OpusCodec)
        XCTAssertTrue(TelephonyProfile.qualityMax.codec      is OpusCodec)
        XCTAssertTrue(TelephonyProfile.latencyLow.codec      is OpusCodec)
        XCTAssertTrue(TelephonyProfile.latencyUltraLow.codec is OpusCodec)
    }

    func testNextProfileWrapsAround() {
        XCTAssertEqual(TelephonyProfile.next(after: TelephonyProfile.available.last!),
                       TelephonyProfile.available.first!)
    }

    // MARK: - LXST 0.4.8: per-profile buffer frames

    func testProfileBufferFramesMatchReference() {
        // Python: Profiles.get_buffer_frames(profile)
        XCTAssertEqual(TelephonyProfile.bandwidthUltraLow.bufferFrames, 2)
        XCTAssertEqual(TelephonyProfile.bandwidthVeryLow.bufferFrames, 2)
        XCTAssertEqual(TelephonyProfile.bandwidthLow.bufferFrames, 2)
        XCTAssertEqual(TelephonyProfile.qualityMedium.bufferFrames, 5)
        XCTAssertEqual(TelephonyProfile.qualityHigh.bufferFrames, 5)
        XCTAssertEqual(TelephonyProfile.qualityMax.bufferFrames, 5)
        XCTAssertEqual(TelephonyProfile.latencyLow.bufferFrames, 3)
        XCTAssertEqual(TelephonyProfile.latencyUltraLow.bufferFrames, 2)
    }

    // MARK: - LXST 0.4.8: mic filter chain toggles

    func testFilterToggleDefaults() {
        // Python: use_agc / use_bandpass / use_echo_cancellation all default True.
        let phone = Telephone(identity: Identity(), transport: Transport())
        XCTAssertTrue(phone.useAGC)
        XCTAssertTrue(phone.useBandpass)
        XCTAssertTrue(phone.useEchoCancellation)
    }
}
