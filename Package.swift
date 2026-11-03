// swift-tools-version: 6.0
import PackageDescription

// Product name drives the built binary path (.build/release/Tower), which
// build-app.sh copies into the bundle as CFBundleExecutable=Tower (it was
// HQClaudeLimits before v0.1; install.sh still recognises an install that runs it).
let package = Package(
    name: "Tower",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Tower",
            path: "Sources/Tower",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "TowerTests",
            dependencies: ["Tower"],
            path: "Tests/TowerTests"
        )
    ]
)
