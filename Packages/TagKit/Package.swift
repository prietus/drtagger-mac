// swift-tools-version: 6.0
import PackageDescription

// Tag writing: the Picard schema mapped from a release candidate, merged
// with what the files already carry, written to every lossless container
// (FLAC, DSF, WAV/AIFF/DFF, APE/WavPack/TTA, ALAC) with the audio bytes
// verified untouched, plus artwork preparation, metadata backups and the
// library organizer (path templates).
let package = Package(
    name: "TagKit",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "TagKit", targets: ["TagKit"]),
    ],
    dependencies: [
        .package(path: "../FLACKit"),
        .package(path: "../ProviderKit"),
        .package(path: "../LibraryKit"),
        .package(path: "../SplitKit"),
    ],
    targets: [
        .target(
            name: "TagKit",
            dependencies: [
                .product(name: "FLACKit", package: "FLACKit"),
                .product(name: "ProviderKit", package: "ProviderKit"),
                .product(name: "LibraryKit", package: "LibraryKit"),
                .product(name: "SplitKit", package: "SplitKit"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "TagKitTests",
            dependencies: ["TagKit"]
        ),
    ]
)
