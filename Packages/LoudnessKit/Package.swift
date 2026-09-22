// swift-tools-version: 6.0
import PackageDescription

// EBU R128 / ITU-R BS.1770 loudness and true peak, measured in Swift on
// PCM decoded by the bundled ffmpeg, and the ReplayGain 2 / R128 tags
// derived from it (track and album).
let package = Package(
    name: "LoudnessKit",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "LoudnessKit", targets: ["LoudnessKit"]),
    ],
    dependencies: [
        .package(path: "../SplitKit"),
    ],
    targets: [
        .target(
            name: "LoudnessKit",
            dependencies: [
                .product(name: "SplitKit", package: "SplitKit"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "LoudnessKitTests",
            dependencies: ["LoudnessKit"]
        ),
    ]
)
