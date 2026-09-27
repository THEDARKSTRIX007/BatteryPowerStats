// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BatterySOT",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "BatterySOT", targets: ["BatterySOT"]),
        .executable(name: "BatterySOTTests", targets: ["BatterySOTTests"])
    ],
    targets: [
        .target(
            name: "BatterySOTCore",
            path: "Sources/BatterySOTCore",
            swiftSettings: [
                .unsafeFlags(["-enable-testing"])
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreGraphics")
            ]
        ),
        .executableTarget(
            name: "BatterySOT",
            dependencies: ["BatterySOTCore"],
            path: "Sources/BatterySOT"
        ),
        .executableTarget(
            name: "BatterySOTTests",
            dependencies: ["BatterySOTCore"],
            path: "Tests/BatterySOTTests",
            swiftSettings: [
                .unsafeFlags(["-enable-testing"])
            ]
        )
    ]
)
