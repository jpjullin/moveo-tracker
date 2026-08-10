import Foundation

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
    case low = "Low"
    case vga = "640 x 480"
    case hd = "1280 x 720"
}

public struct AppSettings: Codable, Equatable, Sendable {
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
        maxHands = min(2, max(1, maxHands))
        cadenceHz = min(60, max(1, cadenceHz))
        zoom = min(10, max(1, zoom))
        rotation = ImageRotation.normalizedDegrees(rotation)
        oscHost = oscHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if oscHost.isEmpty { oscHost = "127.0.0.1" }
        oscPort = min(65_535, max(1, oscPort))
        minimumConfidence = min(1, max(0, minimumConfidence))
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
