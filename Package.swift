// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "HandVisionNative",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "HandVisionNative", targets: ["HandVisionNative"])
    ],
    targets: [
        .target(
            name: "HandVisionCore",
            linkerSettings: [
                .linkedFramework("Vision")
            ]
        ),
        .executableTarget(
            name: "HandVisionNative",
            dependencies: ["HandVisionCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreImage"),
                .linkedFramework("ImageIO"),
                .linkedFramework("Network"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("Vision")
            ]
        ),
        .testTarget(
            name: "HandVisionCoreTests",
            dependencies: ["HandVisionCore"]
        )
    ]
)
