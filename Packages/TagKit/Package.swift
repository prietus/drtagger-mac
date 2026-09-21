// swift-tools-version: 6.0
import PackageDescription

// Tag writing: the Picard schema mapped from a release candidate, merged
// with what the files already carry, written to every lossless container
// (FLAC, DSF, WAV/AIFF/DFF, APE/WavPack/TTA, ALAC) with the audio bytes
// verified untouched, plus artwork preparation and metadata backups.
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
    ],
    targets: [
        .target(
            name: "TagKit",
            dependencies: [
                .product(name: "FLACKit", package: "FLACKit"),
                .product(name: "ProviderKit", package: "ProviderKit"),
                .product(name: "LibraryKit", package: "LibraryKit"),
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
