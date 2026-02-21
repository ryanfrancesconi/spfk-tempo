// swift-tools-version: 6.2
// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi

import PackageDescription

let package = Package(
    name: "spfk-tempo",
    defaultLocalization: "en",
    platforms: [.macOS(.v12), .iOS(.v15)],
    products: [
        .library(
            name: "SPFKTempo",
            targets: ["SPFKTempo", "SPFKTempoC"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/ryanfrancesconi/CXXSoundTouch", from: "2.1.2"),
        .package(url: "https://github.com/ryanfrancesconi/spfk-utils", from: "0.0.3"),
        .package(url: "https://github.com/ryanfrancesconi/spfk-testing", from: "0.0.1"),
    ],
    targets: [
        .target(
            name: "SPFKTempo",
            dependencies: [
                .targetItem(name: "SPFKTempoC", condition: nil),
                .product(name: "SPFKUtils", package: "spfk-utils"),

            ]
        ),
        .target(
            name: "SPFKTempoC",
            dependencies: [
                .product(name: "SoundTouch", package: "CXXSoundTouch")
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include_private")
            ],
            cxxSettings: [
                .headerSearchPath("include_private")
            ]
        ),
        .testTarget(
            name: "SPFKTempoTests",
            dependencies: [
                .targetItem(name: "SPFKTempo", condition: nil),
                .targetItem(name: "SPFKTempoC", condition: nil),
                .product(name: "SPFKTesting", package: "spfk-testing"),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx20
)
