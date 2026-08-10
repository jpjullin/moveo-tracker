import XCTest
import Darwin
@testable import MoveoTrackerCore

final class OSCEncoderTests: XCTestCase {
    func testOSCContractListsEveryNativeModelAddress() {
        XCTAssertTrue(OSCContract.addresses.contains("/hands/active"))
        XCTAssertTrue(OSCContract.addresses.contains("/bodies/active"))
        XCTAssertTrue(OSCContract.addresses.contains("/faces/active"))
        XCTAssertTrue(OSCContract.addresses.contains("/tracking/status"))
    }

    func testHandTrackingAddressesMatchHandVisionNativeExactly() {
        XCTAssertEqual(OSCContract.handTrackingAddresses, [
            "/hand/0/landmarks",
            "/hand/0/meta",
            "/hand/1/landmarks",
            "/hand/1/meta",
            "/hands/active",
            "/tracking/status"
        ])
    }

    func testHandActiveContractKeepsTwoLegacySlotsAndExpandsForMoreHands() {
        XCTAssertEqual(OSCContract.handActiveArguments(handCount: -1), [.int32(0), .int32(0)])
        XCTAssertEqual(OSCContract.handActiveArguments(handCount: 0), [.int32(0), .int32(0)])
        XCTAssertEqual(OSCContract.handActiveArguments(handCount: 1), [.int32(1), .int32(0)])
        XCTAssertEqual(OSCContract.handActiveArguments(handCount: 2), [.int32(1), .int32(1)])
        XCTAssertEqual(
            OSCContract.handActiveArguments(handCount: 8),
            Array(repeating: .int32(1), count: 8)
        )
    }

    func testHandsActivePacketUsesPaddedStringsAndBigEndianInts() throws {
        let packet = try OSCEncoder.encodeMessage(
            address: "/hands/active",
            arguments: [.int32(1), .int32(0)]
        )

        XCTAssertEqual([UInt8](packet), [
            0x2f, 0x68, 0x61, 0x6e, 0x64, 0x73, 0x2f, 0x61,
            0x63, 0x74, 0x69, 0x76, 0x65, 0x00, 0x00, 0x00,
            0x2c, 0x69, 0x69, 0x00,
            0x00, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x00
        ])
    }

    func testLandmarkContractAlwaysEmits63FloatsAndZeroZ() {
        let points = (0..<21).map { index in
            NormalizedLandmark(x: Float(index) / 20, y: 0.25, z: 1)
        }
        let arguments = OSCContract.landmarkArguments(points)

        XCTAssertEqual(arguments.count, 63)
        XCTAssertEqual(Array(arguments.prefix(6)), [
            .float32(0), .float32(0.25), .float32(0),
            .float32(0.05), .float32(0.25), .float32(0)
        ])
        for index in stride(from: 2, to: arguments.count, by: 3) {
            XCTAssertEqual(arguments[index], .float32(0))
        }
    }

    func testMetaContractEmitsNineFloatsInExistingOrder() {
        let meta = HandMeta(
            score: 1,
            pinch01: 2,
            grab01: 3,
            force01: 4,
            spread01: 5,
            palmX: 6,
            palmY: 7,
            palmAngle: 8,
            velocity: 9
        )

        XCTAssertEqual(OSCContract.metaArguments(meta), (1...9).map { .float32(Float($0)) })
    }

    func testTrackingStatusUsesIIIFTypeTags() throws {
        let arguments = OSCContract.trackingStatusArguments(
            appRunning: true,
            trackingActive: true,
            handCount: 2,
            trackingFPS: 20
        )
        let packet = try OSCEncoder.encodeMessage(
            address: "/tracking/status",
            arguments: arguments
        )

        XCTAssertEqual(arguments, [.int32(1), .int32(1), .int32(2), .float32(20)])
        XCTAssertEqual(Array(packet[20..<28]), [
            0x2c, 0x69, 0x69, 0x69, 0x66, 0x00, 0x00, 0x00
        ])
    }

    func testTrackingStatusRemainsLiveWithZeroHandsAndSanitizesMetrics() {
        XCTAssertEqual(
            OSCContract.trackingStatusArguments(
                appRunning: true,
                trackingActive: false,
                handCount: 0,
                trackingFPS: .infinity
            ),
            [.int32(1), .int32(0), .int32(0), .float32(0)]
        )
        XCTAssertEqual(
            OSCContract.trackingStatusArguments(
                appRunning: true,
                trackingActive: true,
                handCount: -1,
                trackingFPS: -5
            ),
            [.int32(1), .int32(1), .int32(0), .float32(0)]
        )
    }

    func testRejectsAddressWithoutLeadingSlash() {
        XCTAssertThrowsError(try OSCEncoder.encodeMessage(address: "hands/active", arguments: []))
    }

    func testMissingUDPListenerIsTreatedAsBestEffortDelivery() {
        XCTAssertTrue(OSCTransportErrorPolicy.isMissingUDPListener(posixCode: ECONNREFUSED))
        XCTAssertFalse(OSCTransportErrorPolicy.isMissingUDPListener(posixCode: EHOSTUNREACH))
    }

    func testPendingOSCBatchesReplaceWholeFramesAndStayBounded() {
        var buffer = OSCBatchBuffer(capacity: 2)
        let oldFrame = [OSCMessage(address: "/frame", arguments: [.int32(1)])]
        let newFrame = [OSCMessage(address: "/frame", arguments: [.int32(2)])]
        let status = [OSCMessage(address: "/status", arguments: [.int32(1)])]
        buffer.store(key: "tracking-frame", messages: oldFrame)
        buffer.store(key: "tracking-status", messages: status)
        buffer.store(key: "tracking-frame", messages: newFrame)

        XCTAssertEqual(buffer.count, 2)
        XCTAssertEqual(buffer.removeFirst()?.messages, newFrame)
        XCTAssertEqual(buffer.removeFirst()?.messages, status)

        buffer.store(key: "one", messages: oldFrame)
        buffer.store(key: "two", messages: oldFrame)
        buffer.store(key: "three", messages: oldFrame)
        XCTAssertEqual(buffer.count, 2)
        XCTAssertEqual(buffer.removeFirst()?.key, "two")
        XCTAssertEqual(buffer.removeFirst()?.key, "three")
    }

    func testOSCSendWindowPreservesInFlightCountAcrossWaitingAndReady() {
        var window = OSCSendWindow(maximumInFlight: 16)
        window.setReady(true)
        XCTAssertTrue(window.canSend(batchSize: 5))
        window.recordSend(batchSize: 5)
        XCTAssertEqual(window.inFlight, 5)

        window.setReady(false)
        window.setReady(true)
        XCTAssertEqual(window.inFlight, 5)
        XCTAssertFalse(window.canSend(batchSize: 12))
        XCTAssertTrue(window.canSend(batchSize: 11))

        window.recordCompletion()
        XCTAssertEqual(window.inFlight, 4)
        window.resetForNewConnection()
        XCTAssertEqual(window.inFlight, 0)
        XCTAssertFalse(window.isReady)
    }

    func testOSCSendWindowAllowsOneOversizedFrameWithoutStallingForever() {
        var window = OSCSendWindow(maximumInFlight: 16)
        window.setReady(true)

        XCTAssertTrue(window.canSend(batchSize: 19))
        window.recordSend(batchSize: 19)
        XCTAssertEqual(window.inFlight, 19)
        XCTAssertFalse(window.canSend(batchSize: 1))

        for _ in 0..<19 { window.recordCompletion() }
        XCTAssertEqual(window.inFlight, 0)
        XCTAssertTrue(window.canSend(batchSize: 19))
    }

    func testSingleBatchSendWindowDoesNotQueueOverlappingTrackingFrames() {
        var window = OSCSendWindow(maximumInFlight: 1)
        window.setReady(true)

        XCTAssertTrue(window.canSend(batchSize: 3))
        window.recordSend(batchSize: 3)
        XCTAssertFalse(window.canSend(batchSize: 3))
        XCTAssertFalse(window.canSend(batchSize: 1))

        for _ in 0..<3 { window.recordCompletion() }
        XCTAssertEqual(window.inFlight, 0)
        XCTAssertTrue(window.canSend(batchSize: 3))
    }
}
