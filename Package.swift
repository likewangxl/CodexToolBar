// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexTouchBar",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "CodexTouchBar", targets: ["CodexTouchBar"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "TouchBarBridge", publicHeadersPath: "include", linkerSettings: [.linkedFramework("AppKit")]),
        .target(name: "MonitorCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "CodexTouchBar", dependencies: ["MonitorCore", "TouchBarBridge"], resources: [.process("Resources")], linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("ServiceManagement"), .linkedFramework("Speech"), .linkedFramework("AVFoundation")]),
        .testTarget(name: "MonitorCoreTests", dependencies: ["MonitorCore"])
    ]
)
