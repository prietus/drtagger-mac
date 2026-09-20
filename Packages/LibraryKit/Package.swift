// swift-tools-version: 6.0
import PackageDescription

// Album discovery: walks folders, recognises SACD ISOs, CD images with CUE
// sheets, multi-file CUEs and plain track folders (single or multi-disc),
// and parses CUE sheets with encoding detection. Pure Foundation, no UI.
let package = Package(
    name: "LibraryKit",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "LibraryKit", targets: ["LibraryKit"]),
    ],
    targets: [
        .target(
            name: "LibraryKit",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "LibraryKitTests",
            dependencies: ["LibraryKit"]
        ),
    ]
)
