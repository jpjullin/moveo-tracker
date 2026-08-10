import Foundation
import Vision

public enum BodyJointMap {
    public static let visionOrder: [VNHumanBodyPoseObservation.JointName] = [
        .nose, .neck,
        .rightShoulder, .rightElbow, .rightWrist,
        .leftShoulder, .leftElbow, .leftWrist,
        .root,
        .rightHip, .rightKnee, .rightAnkle,
        .leftHip, .leftKnee, .leftAnkle,
        .rightEye, .leftEye, .rightEar, .leftEar
    ]
}

public enum BodySkeleton {
    public static let connections: [HandJointConnection] = [
        .init(0, 1),
        .init(1, 2), .init(2, 3), .init(3, 4),
        .init(1, 5), .init(5, 6), .init(6, 7),
        .init(1, 8),
        .init(8, 9), .init(9, 10), .init(10, 11),
        .init(8, 12), .init(12, 13), .init(13, 14),
        .init(0, 15), .init(15, 17),
        .init(0, 16), .init(16, 18)
    ]
}

public struct NativePoseDetection: Equatable, Sendable {
    public var landmarks: [NormalizedLandmark]
    public var confidence: Float

    public init(landmarks: [NormalizedLandmark], confidence: Float) {
        self.landmarks = landmarks
        self.confidence = confidence
    }
}

public enum BodyPoseMapper {
    public static func detection(
        from observation: VNHumanBodyPoseObservation,
        minimumConfidence: Float
    ) throws -> NativePoseDetection? {
        let points = try observation.recognizedPoints(.all)
        let anchors: [VNHumanBodyPoseObservation.JointName] = [.root, .neck, .nose]
        guard anchors.contains(where: { points[$0]?.confidence ?? 0 >= minimumConfidence }) else {
            return nil
        }

        var confidenceTotal: Float = 0
        var confidenceCount: Float = 0
        let landmarks = BodyJointMap.visionOrder.map { joint -> NormalizedLandmark in
            guard let point = points[joint], point.confidence >= minimumConfidence else {
                return NormalizedLandmark(x: 0, y: 0, z: 0)
            }
            confidenceTotal += point.confidence
            confidenceCount += 1
            return NormalizedLandmark(
                x: min(1, max(0, Float(point.location.x))),
                y: min(1, max(0, Float(point.location.y))),
                z: 0
            )
        }
        return NativePoseDetection(
            landmarks: landmarks,
            confidence: confidenceCount > 0 ? confidenceTotal / confidenceCount : 0
        )
    }
}

public struct NativeFaceDetection: Equatable, Sendable {
    public var landmarks: [NormalizedLandmark]
    public var connections: [HandJointConnection]
    public var bounds: CGRect
    public var confidence: Float

    public init(
        landmarks: [NormalizedLandmark],
        connections: [HandJointConnection],
        bounds: CGRect,
        confidence: Float
    ) {
        self.landmarks = landmarks
        self.connections = connections
        self.bounds = bounds
        self.confidence = confidence
    }
}

public enum FacePoseMapper {
    public static let landmarkCount = 80

    public static func detection(from observation: VNFaceObservation) -> NativeFaceDetection {
        var points: [NormalizedLandmark] = []
        var connections: [HandJointConnection] = []
        let bounds = observation.boundingBox

        func append(_ region: VNFaceLandmarkRegion2D?, count: Int, closed: Bool) {
            let start = points.count
            if let region, region.pointCount > 0 {
                let source = (0..<region.pointCount).map { region.normalizedPoints[$0] }
                for index in 0..<count {
                    let position: CGFloat
                    if count == 1 {
                        position = CGFloat(source.count - 1) / 2
                    } else if closed {
                        position = CGFloat(index * source.count) / CGFloat(count)
                    } else {
                        position = CGFloat(index * (source.count - 1)) / CGFloat(count - 1)
                    }
                    let lower = Int(floor(position))
                    let upper = closed ? (lower + 1) % source.count : min(source.count - 1, lower + 1)
                    let fraction = position - CGFloat(lower)
                    let x = source[lower].x + (source[upper].x - source[lower].x) * fraction
                    let y = source[lower].y + (source[upper].y - source[lower].y) * fraction
                    let imageX = Float(bounds.minX + x * bounds.width)
                    let imageY = Float(bounds.minY + y * bounds.height)
                    points.append(NormalizedLandmark(
                        x: min(1, max(0, imageX)),
                        y: min(1, max(0, imageY)),
                        z: 0
                    ))
                }
            } else {
                points.append(contentsOf: repeatElement(
                    NormalizedLandmark(x: 0, y: 0, z: 0),
                    count: count
                ))
            }
            if count > 1 {
                for index in 0..<(count - 1) {
                    connections.append(.init(start + index, start + index + 1))
                }
                if closed, count > 2 {
                    connections.append(.init(start + count - 1, start))
                }
            }
        }

        if let landmarks = observation.landmarks {
            append(landmarks.faceContour, count: 17, closed: false)
            append(landmarks.leftEye, count: 8, closed: true)
            append(landmarks.rightEye, count: 8, closed: true)
            append(landmarks.leftEyebrow, count: 5, closed: false)
            append(landmarks.rightEyebrow, count: 5, closed: false)
            append(landmarks.nose, count: 9, closed: false)
            append(landmarks.noseCrest, count: 3, closed: false)
            append(landmarks.medianLine, count: 3, closed: false)
            append(landmarks.outerLips, count: 12, closed: true)
            append(landmarks.innerLips, count: 8, closed: true)
            append(landmarks.leftPupil, count: 1, closed: false)
            append(landmarks.rightPupil, count: 1, closed: false)
        } else {
            append(nil, count: landmarkCount, closed: false)
        }

        return NativeFaceDetection(
            landmarks: points,
            connections: connections,
            bounds: bounds,
            confidence: observation.confidence
        )
    }
}
