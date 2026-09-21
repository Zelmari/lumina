// swift-tools-version: 6.3

import PackageDescription

let layoutProducts: [Product] = [
    .library(name: "LuminaLayout", targets: ["LuminaLayout"]),
    .library(name: "LuminaIPC", targets: ["LuminaIPC"]),
]

let layoutTargets: [Target] = [
    .target(
        name: "LuminaLayout",
        dependencies: [
            .product(name: "TOMLDecoder", package: "TOMLDecoder"),
        ]
    ),
    .target(name: "LuminaIPC"),
    .testTarget(
        name: "LuminaLayoutTests",
        dependencies: ["LuminaLayout"]
    ),
    .testTarget(
        name: "LuminaIPCTests",
        dependencies: ["LuminaIPC"]
    ),
]

#if os(macOS)
let appleProducts: [Product] = [
    .executable(name: "lumina", targets: ["LuminaCLI"]),
    .executable(name: "lumina-agent", targets: ["LuminaAgent"]),
    // Not "Lumina": default APFS is case-insensitive, so it would collide with "lumina".
    .executable(name: "LuminaExtra", targets: ["Lumina"]),
]
let appleTargets: [Target] = [
    .executableTarget(
        name: "LuminaCLI",
        dependencies: ["LuminaIPC", "LuminaLayout"]
    ),
    .executableTarget(
        name: "LuminaAgent",
        dependencies: ["LuminaLayout", "LuminaIPC"],
        exclude: ["Info.plist", "LuminaAgent.entitlements"]
    ),
    .executableTarget(
        name: "Lumina",
        dependencies: ["LuminaIPC", "LuminaLayout"],
        exclude: ["Info.plist", "Lumina.entitlements"],
        resources: [.copy("Resources/lumina.toml")]
    ),
]
#else
let appleProducts: [Product] = []
let appleTargets: [Target] = []
#endif

let package = Package(
    name: "Lumina",
    platforms: [
        .macOS("15.2"),
    ],
    products: layoutProducts + appleProducts,
    dependencies: [
        .package(url: "https://github.com/dduan/TOMLDecoder", from: "0.4.4"),
    ],
    targets: layoutTargets + appleTargets,
    swiftLanguageModes: [.v6]
)
