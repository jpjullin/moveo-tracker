import Foundation
import Darwin
import Vision

public enum MediaPipeJoint: Int, CaseIterable, Sendable {
    case wrist = 0
    case thumbCMC
    case thumbMCP
    case thumbIP
    case thumbTip
    case indexMCP
    case indexPIP
    case indexDIP
    case indexTip
    case middleMCP
    case middlePIP
    case middleDIP
    case middleTip
    case ringMCP
    case ringPIP
    case ringDIP
    case ringTip
    case pinkyMCP
    case pinkyPIP
    case pinkyDIP
    case pinkyTip
}

public enum HandJointMap {
    public static let visionOrder: [VNHumanHandPoseObservation.JointName] = [
        .wrist,
        .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
        .indexMCP, .indexPIP, .indexDIP, .indexTip,
        .middleMCP, .middlePIP, .middleDIP, .middleTip,
        .ringMCP, .ringPIP, .ringDIP, .ringTip,
        .littleMCP, .littlePIP, .littleDIP, .littleTip
    ]

    public static func isValid() -> Bool {
        visionOrder.count == MediaPipeJoint.allCases.count &&
            MediaPipeJoint.allCases.map(\.rawValue) == Array(0..<21)
    }
}

public struct NormalizedLandmark: Equatable, Sendable {
    public var x: Float
    public var y: Float
    public var z: Float

    public init(x: Float, y: Float, z: Float = 0) {
        self.x = x
        self.y = y
        self.z = z
    }
}

public struct HandMeta: Equatable, Sendable {
    public var score: Float
    public var pinch01: Float
    public var grab01: Float
    public var force01: Float
    public var spread01: Float
    public var palmX: Float
    public var palmY: Float
    public var palmAngle: Float
    public var velocity: Float
}

public struct HandDetection: Equatable, Sendable {
    public var landmarks: [NormalizedLandmark]
    public var meta: HandMeta

    public init(landmarks: [NormalizedLandmark], meta: HandMeta) {
        self.landmarks = landmarks
        self.meta = meta
    }
}

public struct HandJointConnection: Equatable, Sendable {
    public let start: Int
    public let end: Int

    public init(_ start: Int, _ end: Int) {
        self.start = start
        self.end = end
    }
}

public enum HandSkeleton {
    // MediaPipe's canonical palm and five-finger connection topology.
    public static let connections: [HandJointConnection] = [
        .init(0, 1), .init(1, 2), .init(2, 3), .init(3, 4),
        .init(0, 5), .init(5, 6), .init(6, 7), .init(7, 8),
        .init(5, 9), .init(9, 10), .init(10, 11), .init(11, 12),
        .init(9, 13), .init(13, 14), .init(14, 15), .init(15, 16),
        .init(13, 17), .init(0, 17), .init(17, 18), .init(18, 19), .init(19, 20)
    ]
}

public enum HandOverlayGeometry {
    public static func isDrawable(_ landmark: NormalizedLandmark) -> Bool {
        landmark.x != 0 || landmark.y != 0 || landmark.z != 0
    }

    public static func points(
        for landmarks: [NormalizedLandmark],
        in size: CGSize
    ) -> [CGPoint] {
        landmarks.map { landmark in
            CGPoint(
                x: CGFloat(clamp01(landmark.x)) * size.width,
                y: CGFloat(clamp01(landmark.y)) * size.height
            )
        }
    }

    private static func clamp01(_ value: Float) -> Float {
        min(1, max(0, value))
    }
}

public enum PreviewCoverageGeometry {
    public static func coverRect(
        container: CGSize,
        source: CGSize,
        rotationDegrees: Double,
        zoom: Double
    ) -> CGRect {
        guard container.width > 0, container.height > 0,
              source.width > 0, source.height > 0 else { return .zero }

        let radians = CGFloat(ImageRotation.normalizedDegrees(rotationDegrees) * .pi / 180)
        let rotatedWidth = abs(source.width * cos(radians)) + abs(source.height * sin(radians))
        let rotatedHeight = abs(source.width * sin(radians)) + abs(source.height * cos(radians))
        let coverScale = ImageRotation.minimumCoverScale(
            source: source,
            target: container,
            rotationDegrees: rotationDegrees
        )
        let safeZoom = zoom.isFinite ? max(1, zoom) : 1
        let width = rotatedWidth * coverScale * safeZoom
        let height = rotatedHeight * coverScale * safeZoom
        return CGRect(
            x: (container.width - width) / 2,
            y: (container.height - height) / 2,
            width: width,
            height: height
        )
    }
}

public struct FrameCadence: Sendable {
    private var nextDeadline = -Double.infinity

    public init() {}

    public mutating func reset() {
        nextDeadline = -Double.infinity
    }

    public mutating func shouldProcess(timestamp: TimeInterval, targetHz: Double) -> Bool {
        guard timestamp.isFinite else { return false }
        let interval = 1 / max(1, targetHz)
        if !nextDeadline.isFinite || timestamp < nextDeadline - 1 {
            nextDeadline = timestamp
        }

        // Camera timestamps commonly arrive a fraction early. Comparing each
        // frame with the previous processed timestamp can then halve the rate.
        // A fixed deadline advances without accumulating that sample jitter.
        let tolerance = min(0.003, interval * 0.1)
        guard timestamp + tolerance >= nextDeadline else { return false }

        if timestamp - nextDeadline > interval * 4 {
            nextDeadline = timestamp + interval
        } else {
            repeat { nextDeadline += interval }
            while nextDeadline <= timestamp - tolerance
        }
        return true
    }
}

public enum HandPoseMapper {
    public static func landmarks(
        from observation: VNHumanHandPoseObservation,
        minimumConfidence: Float
    ) throws -> ([NormalizedLandmark], Float)? {
        let points = try observation.recognizedPoints(.all)
        guard let wrist = points[.wrist], wrist.confidence >= minimumConfidence else {
            return nil
        }

        var confidenceTotal: Float = 0
        var confidenceCount: Float = 0
        let mapped = HandJointMap.visionOrder.map { joint -> NormalizedLandmark in
            guard let point = points[joint], point.confidence >= minimumConfidence else {
                return NormalizedLandmark(x: 0, y: 0, z: 0)
            }
            confidenceTotal += point.confidence
            confidenceCount += 1
            return landmark(fromROIRelativeLocation: point.location)
        }

        guard mapped.count == 21 else { return nil }
        return (mapped, confidenceCount > 0 ? confidenceTotal / confidenceCount : 0)
    }

    // Vision reports recognized points in normalized coordinates relative to
    // the request's regionOfInterest. Keep that ROI-local normalization and
    // lower-left Y origin for OSC consumers.
    static func landmark(fromROIRelativeLocation location: CGPoint) -> NormalizedLandmark {
        NormalizedLandmark(
            x: clamp01(Float(location.x)),
            y: clamp01(Float(location.y)),
            z: 0
        )
    }

    private static func clamp01(_ value: Float) -> Float {
        min(1, max(0, value))
    }
}

public final class HandMetaCalculator {
    private struct PreviousPalm {
        var point: NormalizedLandmark
        var time: TimeInterval
    }

    private var previousBySlot: [Int: PreviousPalm] = [:]

    public init() {}

    public func reset() {
        previousBySlot.removeAll()
    }

    public func compute(
        landmarks: [NormalizedLandmark],
        score: Float,
        slot: Int,
        timestamp: TimeInterval
    ) -> HandMeta {
        guard landmarks.count == 21 else {
            return HandMeta(
                score: score, pinch01: 0, grab01: 0, force01: 0, spread01: 0,
                palmX: 0.5, palmY: 0.5, palmAngle: 0, velocity: 0
            )
        }

        let palm = average([landmarks[0], landmarks[5], landmarks[9], landmarks[13], landmarks[17]])
        let palmWidth = max(0.001, distance(landmarks[5], landmarks[17]))
        let pinchDistance = distance(landmarks[4], landmarks[8])
        let pinch = 1 - clamp01((pinchDistance - palmWidth * 0.25) / (palmWidth * 1.25))
        let averageTipDistance = [8, 12, 16, 20]
            .map { distance(landmarks[$0], palm) }
            .reduce(0, +) / 4
        let grab = 1 - clamp01((averageTipDistance - palmWidth * 0.45) / (palmWidth * 1.35))
        let spread = clamp01((distance(landmarks[4], landmarks[20]) - palmWidth) / (palmWidth * 2))
        let force = clamp01(grab * 0.6 + pinch * 0.4)
        let angle = atan2(landmarks[9].y - landmarks[0].y, landmarks[9].x - landmarks[0].x)

        var velocity: Float = 0
        if let previous = previousBySlot[slot] {
            let elapsed = max(0.001, timestamp - previous.time)
            velocity = distance(palm, previous.point) / Float(elapsed)
        }
        previousBySlot[slot] = PreviousPalm(point: palm, time: timestamp)

        return HandMeta(
            score: score,
            pinch01: pinch,
            grab01: grab,
            force01: force,
            spread01: spread,
            palmX: palm.x,
            palmY: palm.y,
            palmAngle: angle,
            velocity: velocity
        )
    }

    private func average(_ points: [NormalizedLandmark]) -> NormalizedLandmark {
        let count = Float(max(1, points.count))
        return NormalizedLandmark(
            x: points.reduce(0) { $0 + $1.x } / count,
            y: points.reduce(0) { $0 + $1.y } / count,
            z: 0
        )
    }

    private func distance(_ a: NormalizedLandmark, _ b: NormalizedLandmark) -> Float {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return sqrtf(dx * dx + dy * dy)
    }

    private func clamp01(_ value: Float) -> Float {
        min(1, max(0, value))
    }
}
