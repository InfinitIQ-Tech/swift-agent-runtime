// swift-tools-version: 6.0
import PackageDescription

// Platform floors are intentionally below the Foundation Models floor (iOS 26 /
// macOS 26). Apps with an iOS 17 deployment target must be able to link this
// package; all Foundation Models usage is availability-gated at the call sites.
let package = Package(
    name: "swift-agent-runtime",
    platforms: [
        .iOS(.v17),
        .macOS(.v15)
    ],
    products: [
        .library(name: "AgentRuntime", targets: ["AgentRuntime"]),
        .executable(name: "agent-runtime-demo", targets: ["agent-runtime-demo"])
    ],
    targets: [
        .target(
            name: "AgentRuntime",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .executableTarget(
            name: "agent-runtime-demo",
            dependencies: ["AgentRuntime"]
        ),
        .testTarget(
            name: "AgentRuntimeTests",
            dependencies: ["AgentRuntime"],
            resources: [.copy("Resources")]
        )
    ]
)
