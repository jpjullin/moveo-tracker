// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MoveoTracker",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MoveoTracker", targets: ["MoveoTracker"])
    ],
    targets: [
        .target(
            name: "MoveoTrackerCore",
            linkerSettings: [
                .linkedFramework("Vision")
            ]
        ),
        .executableTarget(
            name: "MoveoTracker",
            dependencies: ["MoveoTrackerCore"],
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
            name: "MoveoTrackerCoreTests",
            dependencies: ["MoveoTrackerCore"]
        )
    ]
)
