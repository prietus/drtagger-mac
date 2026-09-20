// swift-tools-version: 6.0
import PackageDescription

// Scarletbook (SACD ISO) reading and extraction: full disc / area / track
// model with texts and ISRCs, audio sector and frame parsing, DSF writing
// with ID3 tags. Written from the on-disc layout verified against real
// images (see DESIGN.md); no GPL code.
let package = Package(
    name: "SACDKit",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "SACDKit", targets: ["SACDKit"]),
    ],
    dependencies: [
        .package(path: "../LibraryKit"),
        .package(path: "../FLACKit"),
        .package(path: "../SplitKit"),
    ],
    targets: [
        .target(
            name: "SACDKit",
            dependencies: [
                .product(name: "LibraryKit", package: "LibraryKit"),
                .product(name: "FLACKit", package: "FLACKit"),
                .product(name: "SplitKit", package: "SplitKit"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "SACDKitTests",
            dependencies: ["SACDKit"]
        ),
    ]
)
