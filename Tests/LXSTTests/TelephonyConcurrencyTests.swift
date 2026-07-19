import XCTest
import ReticulumSwift
@testable import LXST

/// Concurrency stress test for the `Telephone.pipelineLock` hardening in the
/// 2026-07-19 deferred data-race pass. The rest of the telephony suite is
/// single-threaded and cannot exercise the races on the seven pipeline
/// class-reference FIELDS (receiveMixer / transmitMixer / audioInput / audioOutput
/// / dialTone / receivePipeline / transmitPipeline), which were previously mutated
/// under `pipelineLock` in some paths and lock-free in others (`prepareDiallingPipelines`,
/// the gain/mute accessors, `reconfigureTransmitPipeline`, `disableDialTone`).
///
/// This validates the target of the fix: safe concurrent access to the Telephone
/// FIELD REFERENCES themselves — a stale reference or torn nil-check-then-assign
/// would crash. It deliberately does NOT drive concurrent Mixer/Pipeline METHOD
/// calls on the same object; the underlying Mixer/Pipeline primitives have their
/// own (separately-tracked) internal thread-safety story, out of scope here.
///
/// A lock inversion or reentrant self-deadlock (calling the locking
/// `prepareDiallingPipelines()` wrapper from a path already holding `pipelineLock`)
/// would TIME OUT; a torn field access would CRASH. Passing under ThreadSanitizer
/// (`swift test -Xswiftc -sanitize=thread --filter TelephonyConcurrencyTests`)
/// proves neither happens on the Telephone side.
final class TelephonyConcurrencyTests: XCTestCase {

    func testConcurrentPipelineFieldsDoNotCrashOrRace() {
        let phone = Telephone(identity: Identity(), transport: Transport())
        phone.testSetCallStatus(.available)

        let done = expectation(description: "telephony pipeline stress")
        let workers = 8
        let iterations = 1500

        DispatchQueue.global().async {
            DispatchQueue.concurrentPerform(iterations: workers) { w in
                for i in 0..<iterations {
                    switch (w &+ i) % 5 {
                    case 0: phone.testPreparePipelines()             // populate fields (serialized by pipelineLock)
                    case 1: phone.testResetPipelines()               // stop+nil+rebuild under the lock
                    case 2: phone.testNilPipelines()                 // nil ALL 7 fields under the lock (hangup's clear)
                    case 3: _ = phone.testPipelineFieldsPresent()    // read references under the lock
                    default: _ = phone.testPipelineFieldsPresent()
                    }
                }
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 60)
        _ = phone.testPipelineFieldsPresent()
    }
}
