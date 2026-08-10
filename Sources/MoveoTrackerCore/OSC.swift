import Foundation
import Darwin

public enum OSCArgument: Equatable, Sendable {
    case int32(Int32)
    case float32(Float)
    case string(String)
}

public enum OSCEncodingError: Error, Equatable {
    case invalidAddress
    case embeddedNull
}

public enum OSCEncoder {
    public static func validateMessage(address: String, arguments: [OSCArgument]) throws {
        guard address.first == "/" else { throw OSCEncodingError.invalidAddress }
        guard !address.utf8.contains(0) else { throw OSCEncodingError.embeddedNull }
        for argument in arguments {
            if case .string(let value) = argument, value.utf8.contains(0) {
                throw OSCEncodingError.embeddedNull
            }
        }
    }

    public static func encodeMessage(address: String, arguments: [OSCArgument]) throws -> Data {
        try validateMessage(address: address, arguments: arguments)

        var data = try encodeString(address)
        let tags = "," + arguments.map { argument in
            switch argument {
            case .int32: return "i"
            case .float32: return "f"
            case .string: return "s"
            }
        }.joined()
        data.append(try encodeString(tags))

        for argument in arguments {
            switch argument {
            case .int32(let value):
                appendUInt32(UInt32(bitPattern: value), to: &data)
            case .float32(let value):
                appendUInt32(value.bitPattern, to: &data)
            case .string(let value):
                data.append(try encodeString(value))
            }
        }
        return data
    }

    private static func encodeString(_ value: String) throws -> Data {
        guard !value.utf8.contains(0) else { throw OSCEncodingError.embeddedNull }
        var data = Data(value.utf8)
        data.append(0)
        while data.count % 4 != 0 { data.append(0) }
        return data
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }
}

public enum OSCContract {
    public static let handSlotCount = 2
    public static let handTrackingAddresses = [
        "/hand/0/landmarks",
        "/hand/0/meta",
        "/hand/1/landmarks",
        "/hand/1/meta",
        "/hands/active",
        "/tracking/status"
    ]

    public static let addresses = [
        "/hand/0/landmarks",
        "/hand/0/meta",
        "/hand/1/landmarks",
        "/hand/1/meta",
        "/hands/active",
        "/body/0/landmarks",
        "/body/0/meta",
        "/body/1/landmarks",
        "/body/1/meta",
        "/bodies/active",
        "/face/0/landmarks",
        "/face/0/bounds",
        "/face/1/landmarks",
        "/face/1/bounds",
        "/faces/active",
        "/tracking/status"
    ]

    public static func handActiveArguments(handCount: Int) -> [OSCArgument] {
        let activeCount = max(0, handCount)
        return (0..<max(handSlotCount, activeCount)).map { slot in
            .int32(slot < activeCount ? 1 : 0)
        }
    }

    public static func landmarkArguments(_ landmarks: [NormalizedLandmark]) -> [OSCArgument] {
        landmarks.flatMap { point in
            [.float32(point.x), .float32(point.y), .float32(0)]
        }
    }

    public static func metaArguments(_ meta: HandMeta) -> [OSCArgument] {
        [
            .float32(meta.score),
            .float32(meta.pinch01),
            .float32(meta.grab01),
            .float32(meta.force01),
            .float32(meta.spread01),
            .float32(meta.palmX),
            .float32(meta.palmY),
            .float32(meta.palmAngle),
            .float32(meta.velocity)
        ]
    }

    public static func trackingStatusArguments(
        appRunning: Bool,
        trackingActive: Bool,
        handCount: Int,
        trackingFPS: Double
    ) -> [OSCArgument] {
        let finiteFPS = trackingFPS.isFinite ? max(0, trackingFPS) : 0
        return [
            .int32(appRunning ? 1 : 0),
            .int32(trackingActive ? 1 : 0),
            .int32(Int32(clamping: max(0, handCount))),
            .float32(Float(finiteFPS))
        ]
    }
}

public enum OSCTransportErrorPolicy {
    public static func isMissingUDPListener(posixCode: Int32) -> Bool {
        posixCode == ECONNREFUSED
    }
}

public struct OSCMessage: Equatable, Sendable {
    public let address: String
    public let arguments: [OSCArgument]

    public init(address: String, arguments: [OSCArgument]) {
        self.address = address
        self.arguments = arguments
    }
}

public struct OSCBatchBuffer: Sendable {
    public let capacity: Int
    private var batchesByKey: [String: [OSCMessage]] = [:]
    private var keyOrder: [String] = []

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    public var count: Int { keyOrder.count }

    public var first: (key: String, messages: [OSCMessage])? {
        guard let key = keyOrder.first, let messages = batchesByKey[key] else { return nil }
        return (key, messages)
    }

    public mutating func store(key: String, messages: [OSCMessage]) {
        guard !key.isEmpty, !messages.isEmpty else { return }
        if batchesByKey[key] == nil {
            if keyOrder.count >= capacity {
                let droppedKey = keyOrder.removeFirst()
                batchesByKey.removeValue(forKey: droppedKey)
            }
            keyOrder.append(key)
        }
        batchesByKey[key] = messages
    }

    @discardableResult
    public mutating func removeFirst() -> (key: String, messages: [OSCMessage])? {
        guard !keyOrder.isEmpty else { return nil }
        let key = keyOrder.removeFirst()
        guard let messages = batchesByKey.removeValue(forKey: key) else { return nil }
        return (key, messages)
    }

    public mutating func removeAll(keepingCapacity: Bool = false) {
        batchesByKey.removeAll(keepingCapacity: keepingCapacity)
        keyOrder.removeAll(keepingCapacity: keepingCapacity)
    }
}

public struct OSCSendWindow: Sendable {
    public let maximumInFlight: Int
    public private(set) var inFlight = 0
    public private(set) var isReady = false

    public init(maximumInFlight: Int) {
        self.maximumInFlight = max(1, maximumInFlight)
    }

    public func canSend(batchSize: Int) -> Bool {
        guard batchSize > 0, isReady else { return false }
        if batchSize > maximumInFlight {
            return inFlight == 0
        }
        return inFlight + batchSize <= maximumInFlight
    }

    public mutating func setReady(_ ready: Bool) {
        isReady = ready
    }

    public mutating func recordSend(batchSize: Int) {
        guard canSend(batchSize: batchSize) else { return }
        inFlight += batchSize
    }

    public mutating func recordCompletion() {
        inFlight = max(0, inFlight - 1)
    }

    public mutating func resetForNewConnection() {
        inFlight = 0
        isReady = false
    }
}
