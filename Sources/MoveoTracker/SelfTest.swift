import Foundation
import Darwin
import MoveoTrackerCore
import Vision

enum CameraFreeSelfTest {
    static func run() -> Int32 {
        var failures: [String] = []

        if !HandJointMap.isValid() {
            failures.append("joint ordering is not a contiguous 21-point map")
        }
        if HandJointMap.visionOrder.first != .wrist {
            failures.append("joint 0 is not Vision wrist")
        }
        if HandJointMap.visionOrder.last != .littleTip {
            failures.append("joint 20 is not Vision little-finger tip")
        }
        if BodyJointMap.visionOrder.count != 19 || FacePoseMapper.landmarkCount != 80 {
            failures.append("native body or face landmark contract changed")
        }
        if !OSCContract.addresses.contains("/bodies/active") ||
            !OSCContract.addresses.contains("/faces/active") {
            failures.append("native model OSC addresses are missing")
        }

        do {
            let active = try OSCEncoder.encodeMessage(
                address: "/hands/active",
                arguments: [.int32(1), .int32(0)]
            )
            let expected: [UInt8] = [
                0x2f, 0x68, 0x61, 0x6e, 0x64, 0x73, 0x2f, 0x61,
                0x63, 0x74, 0x69, 0x76, 0x65, 0x00, 0x00, 0x00,
                0x2c, 0x69, 0x69, 0x00,
                0x00, 0x00, 0x00, 0x01,
                0x00, 0x00, 0x00, 0x00
            ]
            if [UInt8](active) != expected {
                failures.append("OSC integer encoding does not match the expected big-endian packet")
            }

            let trackingStatus = try OSCEncoder.encodeMessage(
                address: "/tracking/status",
                arguments: [.int32(1), .int32(1), .int32(2), .float32(20)]
            )
            let statusTags = Array(trackingStatus[20..<28])
            if statusTags != [0x2c, 0x69, 0x69, 0x69, 0x66, 0, 0, 0] {
                failures.append("tracking status does not use iiif OSC type tags")
            }
        } catch {
            failures.append("OSC encoding threw \(error)")
        }

        let sample = (0..<21).map { index in
            NormalizedLandmark(x: Float(index) / 20, y: 0.5, z: 9)
        }
        let landmarkArguments = OSCContract.landmarkArguments(sample)
        if landmarkArguments.count != 63 {
            failures.append("landmark contract does not contain 63 floats")
        }
        for index in stride(from: 2, to: landmarkArguments.count, by: 3) {
            if landmarkArguments[index] != .float32(0) {
                failures.append("landmark z output is not zero")
                break
            }
        }

        var sanitized = AppSettings(maxHands: 9, cadenceHz: 0, zoom: 99, oscPort: 99_999)
        sanitized.sanitize()
        if sanitized.maxHands != 2 || sanitized.cadenceHz != 1 || sanitized.zoom != 10 || sanitized.oscPort != 65_535 {
            failures.append("settings bounds are not enforced")
        }
        let unlimited = AppSettings(maxHands: AppSettings.unlimited)
        if !unlimited.isUnlimited || unlimited.maximumDetectionCount != nil {
            failures.append("unlimited detection setting is not preserved")
        }

        if failures.isEmpty {
            print("{\"ok\":true,\"tests\":8,\"cameraRequired\":false}")
            return 0
        }
        for failure in failures { fputs("self-test: \(failure)\n", stderr) }
        return 1
    }
}
