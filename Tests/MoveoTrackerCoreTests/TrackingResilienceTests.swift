import XCTest
@testable import MoveoTrackerCore

final class TrackingResilienceTests: XCTestCase {
    func testSleepPreservesUserIntentWithoutRunningCapture() {
        var intent = TrackingIntent()
        intent.requestStart()
        XCTAssertTrue(intent.shouldRunCapture)

        intent.systemWillSleep()
        XCTAssertTrue(intent.isRequested)
        XCTAssertFalse(intent.shouldRunCapture)

        intent.systemDidWake()
        XCTAssertTrue(intent.shouldRunCapture)

        intent.requestStop()
        XCTAssertFalse(intent.shouldRunCapture)
    }

    func testWatchdogRequiresAStallAndBacksOffRepeatedRecovery() {
        var watchdog = CaptureWatchdog(stallTimeout: 3, initialBackoff: 4, maximumBackoff: 10)
        watchdog.captureStarted(at: 100)
        XCTAssertFalse(watchdog.shouldRecover(at: 102.99))
        XCTAssertTrue(watchdog.shouldRecover(at: 103))

        watchdog.recordRecoveryAttempt(at: 103)
        XCTAssertEqual(watchdog.recoveryAttemptCount, 1)
        XCTAssertFalse(watchdog.canAttemptRecovery(at: 106.99))
        XCTAssertFalse(watchdog.shouldRecover(at: 106.99))
        XCTAssertTrue(watchdog.shouldRecover(at: 107))

        watchdog.recordRecoveryAttempt(at: 107)
        XCTAssertEqual(watchdog.nextRecoveryNotBefore, 115, accuracy: 0.000_1)
        XCTAssertFalse(watchdog.shouldRecover(at: 114.99))
        XCTAssertTrue(watchdog.shouldRecover(at: 115))
    }

    func testFirstNewSampleProvesRecoveryAndResetsBackoff() {
        var watchdog = CaptureWatchdog(stallTimeout: 1, initialBackoff: 2, maximumBackoff: 10)
        watchdog.captureStarted(at: 0)
        watchdog.recordRecoveryAttempt(at: 1)
        XCTAssertFalse(watchdog.hasReceivedSampleSinceStart)

        watchdog.sampleBufferArrived(at: 1.25)
        XCTAssertTrue(watchdog.hasReceivedSampleSinceStart)
        XCTAssertEqual(watchdog.lastSampleBufferAt, 1.25)
        XCTAssertEqual(watchdog.recoveryAttemptCount, 0)
        XCTAssertFalse(watchdog.shouldRecover(at: 2.24))
        XCTAssertTrue(watchdog.shouldRecover(at: 2.25))
    }

    func testBalancedVisionCadenceRemainsTwentyHzWithThirtyFPSInput() {
        var cadence = FrameCadence()
        let processed = (0...60).filter { frame in
            cadence.shouldProcess(timestamp: Double(frame) / 60, targetHz: 20)
        }
        XCTAssertEqual(processed.count, 21)
    }

    func testLossHysteresisBridgesAtMostTwoFramesAndOneTenthSecond() {
        var hysteresis = HandLossHysteresis()
        let hand = detection(x: 0.4)

        XCTAssertEqual(hysteresis.stabilize(detections: [hand], timestamp: 1), [hand])
        XCTAssertEqual(hysteresis.stabilize(detections: [], timestamp: 1.05).count, 1)
        XCTAssertEqual(hysteresis.stabilize(detections: [], timestamp: 1.10).count, 1)
        XCTAssertTrue(hysteresis.stabilize(detections: [], timestamp: 1.15).isEmpty)
    }

    func testLossPredictionUsesVelocityButStaysBoundedAndNormalized() {
        var hysteresis = HandLossHysteresis(maximumPredictionDistance: 0.12)
        _ = hysteresis.stabilize(detections: [detection(x: 0.80)], timestamp: 2.00)
        _ = hysteresis.stabilize(detections: [detection(x: 0.95)], timestamp: 2.05)

        let predicted = hysteresis.stabilize(detections: [], timestamp: 2.10)
        XCTAssertEqual(predicted.count, 1)
        XCTAssertEqual(predicted[0].landmarks[0].x, 1, accuracy: 0.000_1)
        XCTAssertEqual(predicted[0].meta.palmX, 1, accuracy: 0.000_1)
        XCTAssertTrue(predicted[0].landmarks.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) })
    }

    private func detection(x: Float) -> HandDetection {
        let landmarks = Array(repeating: NormalizedLandmark(x: x, y: 0.5), count: 21)
        let meta = HandMetaCalculator().compute(
            landmarks: landmarks,
            score: 0.9,
            slot: 0,
            timestamp: 0
        )
        return HandDetection(landmarks: landmarks, meta: meta)
    }
}
