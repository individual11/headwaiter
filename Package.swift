// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Headwaiter",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HeadwaiterCore", targets: ["HeadwaiterCore"]),
        .executable(name: "headwaiter-scan", targets: ["headwaiter-scan"]),
    ],
    dependencies: [
        // Automatic updates, in the menu bar app only.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        // Detection pipeline: no UI, no dependencies. Shared by the CLI and the menu bar app.
        .target(name: "HeadwaiterCore"),
        // CLI: prints detected servers; also benchmarks, checks against lsof, captures fixtures, stops.
        .executableTarget(name: "headwaiter-scan", dependencies: ["HeadwaiterCore"]),
        // The menu bar app. Bundle it with scripts/build-app.sh.
        .executableTarget(
            name: "Headwaiter",
            dependencies: ["HeadwaiterCore", .product(name: "Sparkle", package: "Sparkle")]
        ),
        // Probes which process APIs survive the App Sandbox (scripts/sandbox-spike.sh).
        .executableTarget(name: "sandbox-spike"),
        .testTarget(
            name: "HeadwaiterCoreTests",
            dependencies: ["HeadwaiterCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
