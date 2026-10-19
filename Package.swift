// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EliteForge",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "EliteForge", targets: ["EliteForge"]),
        .executable(name: "forgectl", targets: ["forgectl"]),
        .executable(name: "eliteforge-helper", targets: ["eliteforge-helper"]),
        .library(name: "EliteKit", targets: ["EliteKit"]),
    ],
    targets: [
        // Protocol, profile encoding and request logic. Foundation only.
        .target(name: "EliteKit"),
        // IOUSBHost transport. Needs root (or the device-access entitlement) to capture the controller.
        .target(name: "EliteUSB", dependencies: ["EliteKit"], linkerSettings: [.linkedFramework("IOUSBHost"), .linkedFramework("IOKit")]),
        // XPC protocol shared by the app, the CLI and the root helper.
        .target(name: "EliteIPC", dependencies: ["EliteKit"]),
        .executableTarget(name: "eliteforge-helper", dependencies: ["EliteKit", "EliteUSB", "EliteIPC"], linkerSettings: [.linkedFramework("SystemConfiguration")]),
        .executableTarget(name: "forgectl", dependencies: ["EliteKit", "EliteUSB", "EliteIPC"]),
        .executableTarget(name: "EliteForge", dependencies: ["EliteKit", "EliteIPC"]),
        .testTarget(name: "EliteKitTests", dependencies: ["EliteKit"]),
        .testTarget(name: "EliteIPCTests", dependencies: ["EliteIPC", "EliteKit"]),
    ],
    swiftLanguageModes: [.v5]
)
