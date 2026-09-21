// swift-tools-version: 6.0
import PackageDescription

// Release identification: gathers signals from an album (artwork barcodes
// and OCR, existing tags, CUE and SACD texts, disc TOC, CUETools DB hints,
// acoustic fingerprints), queries the providers and ranks candidates with
// an explainable score.
let package = Package(
    name: "IdentifyKit",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "IdentifyKit", targets: ["IdentifyKit"]),
    ],
    dependencies: [
        .package(path: "../LibraryKit"),
        .package(path: "../ProviderKit"),
        .package(path: "../SplitKit"),
        .package(path: "../SACDKit"),
        .package(path: "../Chromaprint"),
    ],
    targets: [
        .target(
            name: "IdentifyKit",
            dependencies: [
                .product(name: "LibraryKit", package: "LibraryKit"),
                .product(name: "ProviderKit", package: "ProviderKit"),
                .product(name: "SplitKit", package: "SplitKit"),
                .product(name: "SACDKit", package: "SACDKit"),
                .product(name: "ChromaprintKit", package: "Chromaprint"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "IdentifyKitTests",
            dependencies: ["IdentifyKit"]
        ),
    ]
)
