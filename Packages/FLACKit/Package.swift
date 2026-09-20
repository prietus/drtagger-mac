// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FLACKit",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "FLACKit", targets: ["FLACKit"]),
        .executable(name: "flacdump", targets: ["flacdump"]),
    ],
    targets: [
        .executableTarget(
            name: "flacdump",
            dependencies: ["FLACKit"]
        ),
        .target(
            name: "FLACKit",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "FLACKitTests",
            dependencies: ["FLACKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
