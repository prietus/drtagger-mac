// swift-tools-version: 6.0
import PackageDescription

// Vendored build of chromaprint 1.5.1 for macOS. We ship the core
// src/ files with the vDSP FFT backend selected (Accelerate.framework)
// so there are zero external dependencies — no kissfft, no fftw3, no
// libav. The avresample/ subfolder is chromaprint's in-tree minimal
// resampler (used by AudioProcessor when ffmpeg isn't available), which
// is exactly our situation on macOS without libav.
//
// LGPL 2.1+: downstream apps must disclose the chromaprint source and
// allow relinking. drtagger ships unmodified 1.5.1 src/ and links
// statically; the attribution lives on the drtagger privacy page.

let package = Package(
    name: "Chromaprint",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "ChromaprintKit", targets: ["ChromaprintKit"]),
    ],
    targets: [
        .target(
            name: "Chromaprint",
            path: "Sources/Chromaprint",
            exclude: [],
            publicHeadersPath: "include",
            cSettings: [
                // resample2.c needs HAVE_LRINTF to use the real lrintf()
                // instead of a floor(x+0.5) macro. Without this, the
                // resampler's filter coefficients can differ from fpcalc's.
                .define("HAVE_LRINTF", to: "1"),
                .headerSearchPath("."),
            ],
            cxxSettings: [
                // Select the Accelerate-based FFT backend. The other
                // backends in src/ are guarded by their own USE_* flags
                // and stay out of the build.
                .define("USE_VDSP", to: "1"),
                // Silence the in-tree DEBUG(x) macro so chromaprint
                // doesn't spam stderr from a release build.
                .define("NDEBUG", to: "1"),
                .define("HAVE_LRINTF", to: "1"),
                // Private headers live alongside the .cpp files and in
                // two subfolders (utils/, audio/, avresample/). Chromaprint
                // uses a mix of "utils/foo.h" and bare "foo.h" includes,
                // so we expose both roots.
                .headerSearchPath("."),
                .headerSearchPath("utils"),
            ],
            linkerSettings: [
                .linkedFramework("Accelerate"),
            ]
        ),
        .target(
            name: "ChromaprintKit",
            dependencies: ["Chromaprint"],
            path: "Sources/ChromaprintKit",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
    ],
    cLanguageStandard: .c11,
    cxxLanguageStandard: .cxx17
)
