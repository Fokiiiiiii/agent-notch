// swift-tools-version:5.10
import PackageDescription
let package = Package(
    name: "agent-notch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AgentNotch",
            path: "Sources/AgentNotch",
            resources: [.process("Resources/Localizable.xcstrings")]
        ),
        .executableTarget(name: "agent-notch-bridge", path: "Sources/agent-notch-bridge"),
    ]
)
