// swift-tools-version: 6.0
import PackageDescription

// Splits CD images described by a CUE sheet into verified FLAC tracks by
// driving the embedded ffmpeg: decode to raw PCM, cut sample-accurate
// ranges, encode FLAC from a pipe, verify the STREAMINFO MD5 against the
// bytes that were fed, and compute CUETools DB style CRCs.
let package = Package(
    name: "SplitKit",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "SplitKit", targets: ["SplitKit"]),
    ],
    dependencies: [
        .package(path: "../LibraryKit"),
        .package(path: "../FLACKit"),
    ],
    targets: [
        .target(
            name: "SplitKit",
            dependencies: [
                .product(name: "LibraryKit", package: "LibraryKit"),
                .product(name: "FLACKit", package: "FLACKit"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "SplitKitTests",
            dependencies: ["SplitKit"]
        ),
    ]
)
