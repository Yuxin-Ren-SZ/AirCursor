// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AirCursor",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "AirCursor", targets: ["AirCursor"]),
    ],
    targets: [
        // Pure, deterministic logic: pointer math, gesture + dwell detection, settings.
        .target(name: "AirCursorCore"),
        // The macOS app: CoreMotion, IOBluetooth, CGEvent synthesis, MediaPlayer, UI.
        .executableTarget(
            name: "AirCursor",
            dependencies: ["AirCursorCore"],
            linkerSettings: [
                .linkedFramework("IOBluetooth"),
                .linkedFramework("CoreMotion"),
                .linkedFramework("MediaPlayer"),
                .linkedFramework("Carbon"),
            ]
        ),
        .testTarget(name: "AirCursorCoreTests", dependencies: ["AirCursorCore"]),
        .testTarget(name: "AirCursorAppTests", dependencies: ["AirCursor"]),
    ],
    swiftLanguageModes: [.v5]
)
