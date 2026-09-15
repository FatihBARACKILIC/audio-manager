// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AudioManagerKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AudioDomain", targets: ["AudioDomain"]),
        .library(name: "AudioPersistence", targets: ["AudioPersistence"]),
        .library(name: "AudioCore", targets: ["AudioCore"]),
    ],
    targets: [
        .target(name: "AudioDomain"),
        .target(name: "AudioPersistence", dependencies: ["AudioDomain"]),
        .target(name: "AudioCore", dependencies: ["AudioDomain"]),
        .testTarget(name: "AudioDomainTests", dependencies: ["AudioDomain"]),
        .testTarget(name: "AudioPersistenceTests", dependencies: ["AudioPersistence", "AudioDomain"]),
        .testTarget(name: "AudioCoreTests", dependencies: ["AudioCore", "AudioDomain"]),
    ]
)
