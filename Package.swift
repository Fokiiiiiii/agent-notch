// swift-tools-version:5.10
import PackageDescription
let package = Package(
    name: "agent-notch",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "AgentNotchCore", path: "Sources/AgentNotchCore"),
        .executableTarget(
            name: "AgentNotch",
            dependencies: ["AgentNotchCore"],
            path: "Sources/AgentNotch",
            resources: [.process("Resources/Localizable.xcstrings")]
        ),
        .executableTarget(
            name: "agent-notch-bridge",
            dependencies: ["AgentNotchCore"],
            path: "Sources/agent-notch-bridge"
        ),
        .testTarget(
            name: "AgentNotchTests",
            dependencies: ["AgentNotch"],
            path: "Tests/AgentNotchTests"
        ),
    ]
)
