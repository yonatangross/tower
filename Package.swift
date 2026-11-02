// swift-tools-version: 6.0
import PackageDescription

// Product name drives the built binary path (.build/release/Tower), which
// build-app.sh copies into the bundle as CFBundleExecutable=HQClaudeLimits.
// The EXECUTABLE name inside the bundle stays HQClaudeLimits on purpose: macOS
// keys TCC grants and the login item off CFBundleIdentifier, and install.sh's
// pkill matches the binary name.
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
