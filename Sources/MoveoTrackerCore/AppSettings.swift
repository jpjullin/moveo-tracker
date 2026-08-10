import Foundation

public enum TrackingMode: String, Codable, CaseIterable, Sendable {
    case hands = "Hands"
    case body = "Body"
    case face = "Face"

    public var subjectLabel: String {
        switch self {
        case .hands: return "hands"
        case .body: return "bodies"
        case .face: return "faces"
        }
    }
}

public enum TrackingPreset: String, Codable, CaseIterable, Sendable {
    case saver = "Saver"
    case eco = "Eco"
    case balanced = "Balanced"
    case smooth = "Smooth"
    case custom = "Custom"

    public var tuning: (maxHands: Int, cadenceHz: Double, resolution: CaptureResolution)? {
        switch self {
        case .saver:
            return (1, 10, .low)
        case .eco:
            return (2, 15, .low)
        case .balanced:
            return (2, 20, .vga)
        case .smooth:
            return (2, 30, .vga)
        case .custom:
            return nil
        }
    }
}

public enum CaptureResolution: String, Codable, CaseIterable, Sendable {
    case ultraLow = "160 x 120"
    case low = "Low"
    case vga = "640 x 480"
    case highFourThree = "960 x 720"
    case ultraLowWidescreen = "320 x 180"
    case lowWidescreen = "640 x 360"
    case widescreen = "960 x 540"
    case hd = "1280 x 720"

    public var displayName: String {
        switch self {
        case .ultraLow: return "160 × 120 (4:3)"
        case .low: return "320 × 240 (4:3)"
        case .vga: return "640 × 480 (4:3)"
        case .highFourThree: return "960 × 720 (4:3)"
        case .ultraLowWidescreen: return "320 × 180 (16:9)"
        case .lowWidescreen: return "640 × 360 (16:9)"
        case .widescreen: return "960 × 540 (16:9)"
        case .hd: return "1280 × 720 (16:9)"
        }
    }

    public var aspectRatio: CGFloat {
        switch self {
        case .ultraLow, .low, .vga, .highFourThree: return 4 / 3
        case .ultraLowWidescreen, .lowWidescreen, .widescreen, .hd: return 16 / 9
        }
    }

    public var pixelDimensions: (width: Int, height: Int) {
        switch self {
        case .ultraLow: return (160, 120)
        case .low: return (320, 240)
        case .vga: return (640, 480)
        case .highFourThree: return (960, 720)
        case .ultraLowWidescreen: return (320, 180)
        case .lowWidescreen: return (640, 360)
        case .widescreen: return (960, 540)
        case .hd: return (1280, 720)
        }
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public static let unlimited = 0
    public static let unlimitedHandRequestLimit = 64

    public var trackingMode: TrackingMode
    public var cameraID: String
    public var preset: TrackingPreset
    public var maxHands: Int
    public var cadenceHz: Double
    public var resolution: CaptureResolution
    public var zoom: Double
    public var rotation: Double
    public var oscHost: String
    public var oscPort: Int
    public var minimumConfidence: Float

    public init(
        trackingMode: TrackingMode = .hands,
        cameraID: String = "",
        preset: TrackingPreset = .balanced,
        maxHands: Int = 2,
        cadenceHz: Double = 20,
        resolution: CaptureResolution = .vga,
        zoom: Double = 1,
        rotation: Double = 0,
        oscHost: String = "127.0.0.1",
        oscPort: Int = 9000,
        minimumConfidence: Float = 0.15
    ) {
        self.trackingMode = trackingMode
        self.cameraID = cameraID
        self.preset = preset
        self.maxHands = maxHands
        self.cadenceHz = cadenceHz
        self.resolution = resolution
        self.zoom = zoom
        self.rotation = rotation
        self.oscHost = oscHost
        self.oscPort = oscPort
        self.minimumConfidence = minimumConfidence
        sanitize()
    }

    private enum CodingKeys: String, CodingKey {
        case trackingMode, cameraID, preset, maxHands, cadenceHz, resolution
        case zoom, rotation, oscHost, oscPort, minimumConfidence
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        trackingMode = try values.decodeIfPresent(TrackingMode.self, forKey: .trackingMode) ?? .hands
        cameraID = try values.decode(String.self, forKey: .cameraID)
        preset = try values.decode(TrackingPreset.self, forKey: .preset)
        maxHands = try values.decode(Int.self, forKey: .maxHands)
        cadenceHz = try values.decode(Double.self, forKey: .cadenceHz)
        resolution = try values.decode(CaptureResolution.self, forKey: .resolution)
        zoom = try values.decode(Double.self, forKey: .zoom)
        rotation = try values.decode(Double.self, forKey: .rotation)
        oscHost = try values.decode(String.self, forKey: .oscHost)
        oscPort = try values.decode(Int.self, forKey: .oscPort)
        minimumConfidence = try values.decode(Float.self, forKey: .minimumConfidence)
        sanitize()
    }

    public static var defaults: AppSettings {
        AppSettings()
    }

    public mutating func applyPreset(_ preset: TrackingPreset) {
        self.preset = preset
        guard let tuning = preset.tuning else { return }
        maxHands = tuning.maxHands
        cadenceHz = tuning.cadenceHz
        resolution = tuning.resolution
        sanitize()
    }

    public mutating func updatePresetFromTuning() {
        preset = TrackingPreset.allCases.first { candidate in
            guard let tuning = candidate.tuning else { return false }
            return tuning.maxHands == maxHands
                && tuning.cadenceHz == cadenceHz
                && tuning.resolution == resolution
        } ?? .custom
    }

    public mutating func sanitize() {
        if maxHands != Self.unlimited {
            maxHands = min(2, max(1, maxHands))
        }
        cadenceHz = min(60, max(1, cadenceHz))
        zoom = min(10, max(1, zoom))
        rotation = ImageRotation.normalizedDegrees(rotation)
        oscHost = oscHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if oscHost.isEmpty { oscHost = "127.0.0.1" }
        oscPort = min(65_535, max(1, oscPort))
        minimumConfidence = min(1, max(0, minimumConfidence))
    }

    public var isUnlimited: Bool {
        maxHands == Self.unlimited
    }

    public var maximumDetectionCount: Int? {
        isUnlimited ? nil : maxHands
    }

    public var maximumHandRequestCount: Int {
        isUnlimited ? Self.unlimitedHandRequestLimit : maxHands
    }
}

public enum ImageRotation {
    public static func normalizedDegrees(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        let normalized = degrees.truncatingRemainder(dividingBy: 360)
        let positive = normalized < 0 ? normalized + 360 : normalized
        return abs(positive - 360) < 0.000_001 ? 0 : positive
    }

    public static func discreteQuarterTurns(_ degrees: Double) -> Int? {
        let normalized = normalizedDegrees(degrees)
        for (value, turns) in [(0.0, 0), (90.0, 1), (180.0, 2), (270.0, 3)] {
            if abs(normalized - value) < 0.000_001 { return turns }
        }
        return nil
    }

    public static func minimumCoverScale(
        source: CGSize,
        target: CGSize,
        rotationDegrees: Double
    ) -> CGFloat {
        guard source.width > 0, source.height > 0,
              target.width > 0, target.height > 0 else { return 1 }
        let radians = CGFloat(normalizedDegrees(rotationDegrees) * .pi / 180)
        let cosine = abs(cos(radians))
        let sine = abs(sin(radians))
        let horizontal = (target.width * cosine + target.height * sine) / source.width
        let vertical = (target.width * sine + target.height * cosine) / source.height
        return max(horizontal, vertical)
    }
}

public final class SettingsPersistence {
    private let defaults: UserDefaults
    private let key = "saved-app-settings-v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> AppSettings {
        guard
            let data = defaults.data(forKey: key),
            var settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else {
            return .defaults
        }
        settings.sanitize()
        return settings
    }

    public func save(_ settings: AppSettings) throws {
        var clean = settings
        clean.sanitize()
        defaults.set(try JSONEncoder().encode(clean), forKey: key)
    }

    public func reset() -> AppSettings {
        defaults.removeObject(forKey: key)
        return .defaults
    }
}
