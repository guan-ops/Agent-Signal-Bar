// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgentSignalLight",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AgentSignalLight", targets: ["AgentSignalLight"]),
        .executable(name: "agent-signal", targets: ["AgentSignalCLI"]),
        .executable(name: "agent-signal-checks", targets: ["AgentSignalChecks"]),
        .executable(name: "agent-signal-icon-preview", targets: ["AgentSignalIconPreview"]),
        .library(name: "AgentSignalLightCore", targets: ["AgentSignalLightCore"]),
        .library(name: "AgentSignalLightUI", targets: ["AgentSignalLightUI"])
    ],
    targets: [
        .target(name: "AgentSignalLightCore"),
        .target(
            name: "AgentSignalLightUI",
            dependencies: ["AgentSignalLightCore"]
        ),
        .executableTarget(
            name: "AgentSignalLight",
            dependencies: [
                "AgentSignalLightCore",
                "AgentSignalLightUI"
            ]
        ),
        .executableTarget(
            name: "AgentSignalCLI",
            dependencies: ["AgentSignalLightCore"]
        ),
        .executableTarget(
            name: "AgentSignalChecks",
            dependencies: ["AgentSignalLightCore"]
        ),
        .executableTarget(
            name: "AgentSignalIconPreview",
            dependencies: [
                "AgentSignalLightCore",
                "AgentSignalLightUI"
            ]
        ),
        .testTarget(
            name: "AgentSignalLightCoreTests",
            dependencies: [
                "AgentSignalLight",
                "AgentSignalLightCore",
                "AgentSignalLightUI"
            ]
        )
    ]
)
