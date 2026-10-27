// swift-tools-version: 6.2
// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi

import PackageDescription

let package = Package(
    name: "spfk-tempo",
    defaultLocalization: "en",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(
            name: "SPFKTempo",
            targets: ["SPFKTempo"]
        ),
        .library(
            name: "SPFKTimePitchKernel",
            targets: ["SPFKTimePitchKernel"]
        ),

        // Measurements of the time/pitch kernel. An executable rather than a test suite because the
        // numbers only mean anything compiled `-O`.
        .executable(name: "spfk-time-pitch-bench", targets: ["TimePitchBench"]),

        // Scores the tempo detector against a labeled corpus -- see Sources/TempoEval.
        .executable(name: "spfk-tempo-eval", targets: ["TempoEval"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ryanfrancesconi/spfk-audio-base", from: "1.6.1"),
        .package(url: "https://github.com/ryanfrancesconi/spfk-testing", from: "1.1.0"),
    ],
    targets: [
        .target(
            name: "SPFKTempo",
            dependencies: [
                .targetItem(name: "SPFKTimePitchKernel", condition: nil),
                .product(name: "SPFKAudioBase", package: "spfk-audio-base"),
            ]
        ),
        // Signalsmith Stretch and Signalsmith Linear are vendored, header-only, under `vendor/`.
        .target(
            name: "SPFKTimePitchKernel",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("vendor"),
                .define("SIGNALSMITH_USE_ACCELERATE"),
            ],
            linkerSettings: [
                .linkedFramework("Accelerate"),
            ]
        ),
        .executableTarget(
            name: "TimePitchBench",
            dependencies: [
                .targetItem(name: "SPFKTimePitchKernel", condition: nil),
            ]
        ),
        .executableTarget(
            name: "TempoEval",
            dependencies: [
                .targetItem(name: "SPFKTempo", condition: nil),
                .product(name: "SPFKAudioBase", package: "spfk-audio-base"),
            ]
        ),
        .testTarget(
            name: "SPFKTempoTests",
            dependencies: [
                .targetItem(name: "SPFKTempo", condition: nil),
                .product(name: "SPFKTesting", package: "spfk-testing"),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx20
)
