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
        )
    ],
    dependencies: [
        .package(url: "https://github.com/ryanfrancesconi/spfk-audio-base", from: "0.0.6"),
        .package(url: "https://github.com/ryanfrancesconi/spfk-testing", from: "0.0.5"),
    ],
    targets: [
        .target(
            name: "SPFKTempo",
            dependencies: [
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
    ]
)
