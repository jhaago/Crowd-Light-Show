// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CrowdLightBridge",
    platforms: [
        .macOS(.v11)
    ],
    products: [
        .executable(name: "CrowdLightBridge", targets: ["CrowdLightBridge"])
    ],
    targets: [
        .executableTarget(
            name: "CrowdLightBridge",
            linkerSettings: [
                .linkedFramework("CoreMIDI")
            ]
        )
    ]
)
