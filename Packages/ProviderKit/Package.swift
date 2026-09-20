// swift-tools-version: 6.0
import PackageDescription

// Metadata provider clients (MusicBrainz, AcoustID, Discogs, …) and the
// provider-agnostic `Candidate` model. Forked from drtagger's
// DrtaggerNetwork on 2026-09-20; the WebDAV storage backend was dropped
// because the Mac app only reads local and mounted volumes.
let package = Package(
    name: "ProviderKit",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "ProviderKit", targets: ["ProviderKit"]),
    ],
    targets: [
        .target(
            name: "ProviderKit",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "ProviderKitTests",
            dependencies: ["ProviderKit"]
        ),
    ]
)
