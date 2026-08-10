import Foundation

public struct TrackingIntent: Sendable {
    public private(set) var isRequested = false
    public private(set) var isSleeping = false

    public init() {}

    public var shouldRunCapture: Bool {
        isRequested && !isSleeping
    }

    public mutating func requestStart() {
        isRequested = true
    }

    public mutating func requestStop() {
        isRequested = false
    }

    public mutating func systemWillSleep() {
        isSleeping = true
    }

    public mutating func systemDidWake() {
        isSleeping = false
    }
}

public struct CaptureWatchdog: Sendable {
    public let stallTimeout: TimeInterval
    public let initialBackoff: TimeInterval
    public let maximumBackoff: TimeInterval

    public private(set) var captureStartedAt: TimeInterval?
    public private(set) var lastSampleBufferAt: TimeInterval?
    public private(set) var recoveryAttemptCount = 0
    public private(set) var nextRecoveryNotBefore = -Double.infinity

    public init(
        stallTimeout: TimeInterval = 3,
        initialBackoff: TimeInterval = 1,
        maximumBackoff: TimeInterval = 30
    ) {
        self.stallTimeout = max(0.1, stallTimeout)
        self.initialBackoff = max(0.1, initialBackoff)
        self.maximumBackoff = max(self.initialBackoff, maximumBackoff)
    }

    public var hasReceivedSampleSinceStart: Bool {
        lastSampleBufferAt != nil
    }

    public mutating func captureStarted(at timestamp: TimeInterval) {
        guard timestamp.isFinite else { return }
        captureStartedAt = timestamp
        lastSampleBufferAt = nil
    }

    public mutating func sampleBufferArrived(at timestamp: TimeInterval) {
        guard timestamp.isFinite else { return }
        if captureStartedAt == nil { captureStartedAt = timestamp }
        lastSampleBufferAt = timestamp
        recoveryAttemptCount = 0
        nextRecoveryNotBefore = -Double.infinity
    }

    public func lastSampleAge(at timestamp: TimeInterval) -> TimeInterval? {
        guard timestamp.isFinite, let lastSampleBufferAt else { return nil }
        return max(0, timestamp - lastSampleBufferAt)
    }

    public func shouldRecover(at timestamp: TimeInterval) -> Bool {
        guard timestamp.isFinite, let captureStartedAt else { return false }
        let mostRecentFrame = lastSampleBufferAt ?? captureStartedAt
        return timestamp - mostRecentFrame >= stallTimeout && canAttemptRecovery(at: timestamp)
    }

    public func canAttemptRecovery(at timestamp: TimeInterval) -> Bool {
        timestamp.isFinite && timestamp >= nextRecoveryNotBefore
    }

    public mutating func recordRecoveryAttempt(at timestamp: TimeInterval) {
        guard timestamp.isFinite else { return }
        recoveryAttemptCount += 1
        let exponent = min(20, recoveryAttemptCount - 1)
        let delay = min(maximumBackoff, initialBackoff * pow(2, Double(exponent)))
        nextRecoveryNotBefore = timestamp + delay
        captureStartedAt = timestamp
        lastSampleBufferAt = nil
    }

    public mutating func stop() {
        captureStartedAt = nil
        lastSampleBufferAt = nil
        recoveryAttemptCount = 0
        nextRecoveryNotBefore = -Double.infinity
    }
}

public struct HandLossHysteresis: Sendable {
    private struct TimedFrame: Sendable {
        var detections: [HandDetection]
        var timestamp: TimeInterval
    }

    public let maximumMissedFrames: Int
    public let maximumGap: TimeInterval
    public let maximumPredictionDistance: Float

    private var previousFrame: TimedFrame?
    private var lastFrame: TimedFrame?
    private var missedFrames = 0

    public init(
        maximumMissedFrames: Int = 2,
        maximumGap: TimeInterval = 0.1,
        maximumPredictionDistance: Float = 0.12
    ) {
        self.maximumMissedFrames = max(0, maximumMissedFrames)
        self.maximumGap = max(0, maximumGap)
        self.maximumPredictionDistance = max(0, maximumPredictionDistance)
    }

    public mutating func reset() {
        previousFrame = nil
        lastFrame = nil
        missedFrames = 0
    }

    public mutating func stabilize(
        detections: [HandDetection],
        timestamp: TimeInterval
    ) -> [HandDetection] {
        guard timestamp.isFinite else { return detections }

        if !detections.isEmpty {
            if let lastFrame, lastFrame.detections.count == detections.count {
                previousFrame = lastFrame
            } else {
                previousFrame = nil
            }
            lastFrame = TimedFrame(detections: detections, timestamp: timestamp)
            missedFrames = 0
            return detections
        }

        guard let lastFrame else { return [] }
        missedFrames += 1
        let age = timestamp - lastFrame.timestamp
        guard age >= 0,
              missedFrames <= maximumMissedFrames,
              age <= maximumGap + 1e-9 else {
            reset()
            return []
        }

        guard let previousFrame,
              previousFrame.detections.count == lastFrame.detections.count,
              lastFrame.timestamp > previousFrame.timestamp else {
            return lastFrame.detections
        }

        let scale = Float(age / (lastFrame.timestamp - previousFrame.timestamp))
        return zip(lastFrame.detections, previousFrame.detections).map { current, previous in
            predict(current: current, previous: previous, scale: scale)
        }
    }

    private func predict(
        current: HandDetection,
        previous: HandDetection,
        scale: Float
    ) -> HandDetection {
        guard current.landmarks.count == 21, previous.landmarks.count == 21 else { return current }
        var predicted = current
        predicted.landmarks = zip(current.landmarks, previous.landmarks).map { point, oldPoint in
            guard point.x != 0 || point.y != 0 || point.z != 0,
                  oldPoint.x != 0 || oldPoint.y != 0 || oldPoint.z != 0 else {
                return point
            }

            var dx = (point.x - oldPoint.x) * scale
            var dy = (point.y - oldPoint.y) * scale
            let distance = sqrtf(dx * dx + dy * dy)
            if distance > maximumPredictionDistance, distance > 0 {
                let bound = maximumPredictionDistance / distance
                dx *= bound
                dy *= bound
            }
            return NormalizedLandmark(
                x: clamp01(point.x + dx),
                y: clamp01(point.y + dy),
                z: 0
            )
        }

        let palmIndices = [0, 5, 9, 13, 17]
        let palm = palmIndices.map { predicted.landmarks[$0] }
        let count = Float(palm.count)
        predicted.meta.palmX = palm.reduce(0) { $0 + $1.x } / count
        predicted.meta.palmY = palm.reduce(0) { $0 + $1.y } / count
        return predicted
    }

    private func clamp01(_ value: Float) -> Float {
        min(1, max(0, value))
    }
}
