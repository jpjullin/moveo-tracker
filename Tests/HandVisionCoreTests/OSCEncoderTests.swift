import XCTest
import Darwin
@testable import HandVisionCore

final class OSCEncoderTests: XCTestCase {
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
        let oldFrame = [Data([1]), Data([2]), Data([3])]
        let newFrame = [Data([4]), Data([5]), Data([6])]
        buffer.store(key: "tracking-frame", payloads: oldFrame)
        buffer.store(key: "tracking-status", payloads: [Data([7])])
        buffer.store(key: "tracking-frame", payloads: newFrame)

        XCTAssertEqual(buffer.count, 2)
        XCTAssertEqual(buffer.removeFirst()?.payloads, newFrame)
        XCTAssertEqual(buffer.removeFirst()?.payloads, [Data([7])])

        buffer.store(key: "one", payloads: [Data([1])])
        buffer.store(key: "two", payloads: [Data([2])])
        buffer.store(key: "three", payloads: [Data([3])])
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
}
