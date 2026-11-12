// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Vorsmate",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Vorsmate", targets: ["Vorsmate"]),
        .executable(name: "VorsmateFanHelper", targets: ["VorsmateFanHelper"]),
    ],
    targets: [
        .target(name: "VorsmateCore", exclude: ["AGENTS.md"]),
        .target(
            name: "CAudioListeners", exclude: ["AGENTS.md"], publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("CoreAudio")]),
        .target(
            name: "CReceiverStatus", exclude: ["AGENTS.md"], publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]),
        .target(
            name: "VorsmateSystem", dependencies: ["VorsmateCore", "CAudioListeners", "CReceiverStatus"],
            exclude: ["AGENTS.md"]),
        .target(
            name: "CSMC", exclude: ["AGENTS.md"], publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("IOKit")]),
        .target(name: "VorsmateFan", dependencies: ["VorsmateCore", "CSMC"], exclude: ["AGENTS.md"]),
        .executableTarget(name: "VorsmateFanHelper", dependencies: ["VorsmateFan"], exclude: ["AGENTS.md"]),
        .executableTarget(
            name: "Vorsmate", dependencies: ["VorsmateCore", "VorsmateSystem", "VorsmateFan"], exclude: ["AGENTS.md"]),
        .testTarget(
            name: "VorsmateCoreTests", dependencies: ["VorsmateCore", "VorsmateSystem", "VorsmateFan"],
            exclude: ["AGENTS.md"]),
    ]
)
