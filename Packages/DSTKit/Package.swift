// swift-tools-version: 6.0
import PackageDescription

// DST (Direct Stream Transfer, ISO/IEC 14496-3 subpart 10) decoder that
// outputs the DSD bitstream, for lossless extraction of DST-compressed
// SACD areas. The decoding logic is a Swift port of FFmpeg's libavcodec
// dstdec.c (LGPL 2.1+, (c) 2014 Peter Ross); see LICENSE in this package.
let package = Package(
    name: "DSTKit",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "DSTKit", targets: ["DSTKit"]),
    ],
    targets: [
        .target(
            name: "DSTKit",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "DSTKitTests",
            dependencies: ["DSTKit"]
        ),
    ]
)
