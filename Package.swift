// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeUsageMonitor",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ClaudeUsageMonitor",
            path: "Sources/ClaudeUsageMonitor"
        )
    ]
)
