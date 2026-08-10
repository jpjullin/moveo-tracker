import Vision
import XCTest
@testable import MoveoTrackerCore

final class JointOrderingTests: XCTestCase {
    func testMediaPipeCompatibleJointOrdering() {
        XCTAssertTrue(HandJointMap.isValid())
        XCTAssertEqual(HandJointMap.visionOrder, [
            .wrist,
            .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
            .indexMCP, .indexPIP, .indexDIP, .indexTip,
            .middleMCP, .middlePIP, .middleDIP, .middleTip,
            .ringMCP, .ringPIP, .ringDIP, .ringTip,
            .littleMCP, .littlePIP, .littleDIP, .littleTip
        ])
    }

    func testNativeBodyAndFaceContractsStayStable() {
        XCTAssertEqual(BodyJointMap.visionOrder.count, 19)
        XCTAssertEqual(BodyJointMap.visionOrder.first, .nose)
        XCTAssertEqual(BodyJointMap.visionOrder.last, .leftEar)
        XCTAssertTrue(BodySkeleton.connections.allSatisfy {
            BodyJointMap.visionOrder.indices.contains($0.start)
                && BodyJointMap.visionOrder.indices.contains($0.end)
        })
        XCTAssertEqual(FacePoseMapper.landmarkCount, 80)
    }

    func testCaptureResolutionLabelsShowExactPixelDimensions() {
        XCTAssertEqual(CaptureResolution.ultraLow.displayName, "160 × 120 (4:3)")
        XCTAssertEqual(CaptureResolution.low.displayName, "320 × 240 (4:3)")
        XCTAssertEqual(CaptureResolution.vga.displayName, "640 × 480 (4:3)")
        XCTAssertEqual(CaptureResolution.highFourThree.displayName, "960 × 720 (4:3)")
        XCTAssertEqual(CaptureResolution.ultraLowWidescreen.displayName, "320 × 180 (16:9)")
        XCTAssertEqual(CaptureResolution.lowWidescreen.displayName, "640 × 360 (16:9)")
        XCTAssertEqual(CaptureResolution.widescreen.displayName, "960 × 540 (16:9)")
        XCTAssertEqual(CaptureResolution.hd.displayName, "1280 × 720 (16:9)")
        XCTAssertEqual(CaptureResolution.widescreen.aspectRatio, 16 / 9)
        XCTAssertEqual(CaptureResolution.highFourThree.pixelDimensions.width, 960)
        XCTAssertEqual(CaptureResolution.lowWidescreen.pixelDimensions.height, 360)
        XCTAssertEqual(CaptureResolution.allCases.count, 8)
    }

    func testSettingsAreBoundedToSupportedValues() {
        var settings = AppSettings(
            maxHands: 8,
            cadenceHz: 0,
            zoom: 17,
            rotation: 405,
            oscHost: "  ",
            oscPort: 90_000,
            minimumConfidence: -1
        )
        settings.sanitize()

        XCTAssertEqual(settings.maxHands, 2)
        XCTAssertEqual(settings.cadenceHz, 1)
        XCTAssertEqual(settings.zoom, 10)
        XCTAssertEqual(settings.rotation, 45)
        XCTAssertEqual(settings.oscHost, "127.0.0.1")
        XCTAssertEqual(settings.oscPort, 65_535)
        XCTAssertEqual(settings.minimumConfidence, 0)
    }

    func testUnlimitedDetectionLimitIsPreserved() {
        var settings = AppSettings(maxHands: AppSettings.unlimited)
        settings.sanitize()

        XCTAssertTrue(settings.isUnlimited)
        XCTAssertNil(settings.maximumDetectionCount)
        XCTAssertEqual(settings.maximumHandRequestCount, AppSettings.unlimitedHandRequestLimit)

        settings.updatePresetFromTuning()
        XCTAssertEqual(settings.preset, .custom)
    }

    func testBalancedPresetMatchesPrototypeDefaults() {
        var settings = AppSettings.defaults
        settings.applyPreset(.balanced)

        XCTAssertEqual(settings.maxHands, 2)
        XCTAssertEqual(settings.cadenceHz, 20)
        XCTAssertEqual(settings.resolution, .vga)
    }

    func testCustomPresetTracksManualPerformanceSettings() {
        var settings = AppSettings.defaults
        settings.cadenceHz = 40
        settings.updatePresetFromTuning()
        XCTAssertEqual(settings.preset, .custom)

        settings.maxHands = 1
        settings.cadenceHz = 10
        settings.resolution = .low
        settings.updatePresetFromTuning()
        XCTAssertEqual(settings.preset, .saver)

        settings.applyPreset(.custom)
        XCTAssertEqual(settings.maxHands, 1)
        XCTAssertEqual(settings.cadenceHz, 10)
        XCTAssertEqual(settings.resolution, .low)
    }

    func testVisionPointsRemainNormalizedWithinTheRequestROIWithLowerLeftY() {
        let point = HandPoseMapper.landmark(
            fromROIRelativeLocation: CGPoint(x: 0.2, y: 0.75)
        )

        XCTAssertEqual(point, NormalizedLandmark(x: 0.2, y: 0.75, z: 0))
    }

    func testCadenceDoesNotHalveWhenCameraTimestampsArriveSlightlyEarly() {
        for targetHz in [10.0, 15.0, 20.0, 30.0] {
            var cadence = FrameCadence()
            let processed = (0..<300).reduce(into: 0) { count, index in
                let jitter = index.isMultiple(of: 2) ? -0.0008 : 0.0004
                let timestamp = Double(index) / 30 + (index == 0 ? 0 : jitter)
                if cadence.shouldProcess(timestamp: timestamp, targetHz: targetHz) {
                    count += 1
                }
            }
            XCTAssertEqual(processed, Int(targetHz * 10), accuracy: 1)
        }
    }

    func testDiscreteAndArbitraryRotationsAreNormalized() {
        XCTAssertEqual(ImageRotation.discreteQuarterTurns(0), 0)
        XCTAssertEqual(ImageRotation.discreteQuarterTurns(90), 1)
        XCTAssertEqual(ImageRotation.discreteQuarterTurns(180), 2)
        XCTAssertEqual(ImageRotation.discreteQuarterTurns(270), 3)
        XCTAssertEqual(ImageRotation.discreteQuarterTurns(360), 0)
        XCTAssertNil(ImageRotation.discreteQuarterTurns(12.5))
        XCTAssertEqual(ImageRotation.normalizedDegrees(-17.5), 342.5)
        XCTAssertEqual(ImageRotation.normalizedDegrees(.infinity), 0)
    }

    func testRotatedPreviewCoverRectFillsWithoutMargins() {
        let container = CGSize(width: 640, height: 360)
        let source = CGSize(width: 640, height: 480)

        for rotation in stride(from: 0.0, through: 355.0, by: 5.0) {
            let rect = PreviewCoverageGeometry.coverRect(
                container: container,
                source: source,
                rotationDegrees: rotation,
                zoom: 1
            )
            XCTAssertGreaterThanOrEqual(rect.width, container.width - 0.001)
            XCTAssertGreaterThanOrEqual(rect.height, container.height - 0.001)
            XCTAssertEqual(rect.midX, container.width / 2, accuracy: 0.001)
            XCTAssertEqual(rect.midY, container.height / 2, accuracy: 0.001)

            let scale = ImageRotation.minimumCoverScale(
                source: source,
                target: container,
                rotationDegrees: rotation
            )
            let radians = CGFloat(rotation * .pi / 180)
            let cosine = abs(cos(radians))
            let sine = abs(sin(radians))
            XCTAssertGreaterThanOrEqual(
                source.width * scale + 0.001,
                container.width * cosine + container.height * sine
            )
            XCTAssertGreaterThanOrEqual(
                source.height * scale + 0.001,
                container.width * sine + container.height * cosine
            )
        }
    }

    func testPreviewZoomExpandsTheSameCenteredCoverRect() {
        let normal = PreviewCoverageGeometry.coverRect(
            container: CGSize(width: 640, height: 360),
            source: CGSize(width: 640, height: 480),
            rotationDegrees: 32,
            zoom: 1
        )
        let zoomed = PreviewCoverageGeometry.coverRect(
            container: CGSize(width: 640, height: 360),
            source: CGSize(width: 640, height: 480),
            rotationDegrees: 32,
            zoom: 2
        )

        XCTAssertEqual(zoomed.width, normal.width * 2, accuracy: 0.001)
        XCTAssertEqual(zoomed.height, normal.height * 2, accuracy: 0.001)
        XCTAssertEqual(zoomed.midX, normal.midX, accuracy: 0.001)
        XCTAssertEqual(zoomed.midY, normal.midY, accuracy: 0.001)
    }

    func testROILocalDetectionsMapToVisibleViewportAtAnyZoom() {
        let viewport = CGSize(width: 640, height: 360)
        let zoomedSource = PreviewCoverageGeometry.coverRect(
            container: viewport,
            source: viewport,
            rotationDegrees: 0,
            zoom: 3
        )
        let points = HandOverlayGeometry.points(
            for: [
                NormalizedLandmark(x: 0, y: 0),
                NormalizedLandmark(x: 0.5, y: 0.5),
                NormalizedLandmark(x: 1, y: 1)
            ],
            in: viewport
        )

        XCTAssertEqual(zoomedSource.width, viewport.width * 3)
        XCTAssertEqual(points, [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 320, y: 180),
            CGPoint(x: 640, y: 360)
        ])
    }

    func testSettingsSaveLoadAndReset() throws {
        let suiteName = "MoveoTrackerCoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = SettingsPersistence(defaults: defaults)
        let saved = AppSettings(
            cameraID: "test-camera",
            preset: .smooth,
            maxHands: 1,
            cadenceHz: 40,
            resolution: .hd,
            zoom: 2.5,
            rotation: 270,
            oscHost: "192.0.2.1",
            oscPort: 12_345,
            minimumConfidence: 0.4
        )

        try persistence.save(saved)
        XCTAssertEqual(persistence.load(), saved)
        XCTAssertEqual(persistence.reset(), .defaults)
        XCTAssertEqual(persistence.load(), .defaults)
    }

    func testLegacyIntegerRotationDecodesIntoDoubleSetting() throws {
        let legacyJSON = Data("""
        {
          "cameraID": "legacy-camera",
          "preset": "Balanced",
          "maxHands": 2,
          "cadenceHz": 20,
          "resolution": "640 x 480",
          "zoom": 1.25,
          "rotation": 90,
          "oscHost": "127.0.0.1",
          "oscPort": 9000,
          "minimumConfidence": 0.15
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacyJSON)
        XCTAssertEqual(decoded.trackingMode, .hands)
        XCTAssertEqual(decoded.rotation, 90)
        XCTAssertEqual(ImageRotation.discreteQuarterTurns(decoded.rotation), 1)
    }


    func testTrackingModeRoundTripsWithSavedSettings() throws {
        let settings = AppSettings(trackingMode: .face)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.trackingMode, .face)
    }

    func testOverlayMapsROILocalLowerLeftCoordinatesIntoLayerSpace() {
        let points = HandOverlayGeometry.points(
            for: [
                NormalizedLandmark(x: 0, y: 0),
                NormalizedLandmark(x: 0.5, y: 0.25),
                NormalizedLandmark(x: 1, y: 1)
            ],
            in: CGSize(width: 200, height: 100)
        )

        XCTAssertEqual(points, [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 100, y: 25),
            CGPoint(x: 200, y: 100)
        ])
    }

    func testMediaPipeSkeletonConnectionsCoverValidJointIndices() {
        XCTAssertEqual(HandSkeleton.connections.count, 21)
        XCTAssertTrue(HandSkeleton.connections.allSatisfy {
            (0..<21).contains($0.start) && (0..<21).contains($0.end)
        })
        XCTAssertTrue(HandSkeleton.connections.contains(.init(0, 1)))
        XCTAssertTrue(HandSkeleton.connections.contains(.init(19, 20)))
    }

    func testOverlaySkipsMissingJointSentinelWithoutChangingLandmarkData() {
        let missing = NormalizedLandmark(x: 0, y: 0, z: 0)
        let recognized = NormalizedLandmark(x: 0.25, y: 0.5, z: 0)

        XCTAssertFalse(HandOverlayGeometry.isDrawable(missing))
        XCTAssertTrue(HandOverlayGeometry.isDrawable(recognized))
        XCTAssertEqual(missing, NormalizedLandmark(x: 0, y: 0, z: 0))
    }
}
