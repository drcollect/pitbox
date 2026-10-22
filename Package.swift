// swift-tools-version: 6.2
import PackageDescription

// Pitbox: one package, one app. The targets and where each part lives: docs/ARCHITECTURE.md.
//
// The only third-party dependency is SwiftTerm (MIT), a terminal emulator engine, pinned to an exact version so every
// build uses the reviewed code; `Package.resolved` is committed. Review the diff before bumping it.
//
// `pitbox-command-helper` is the exec shim of the console's command tabs: the app bundle carries it next to its main
// executable (`Contents/MacOS/pitbox-command-helper`, built and signed by scripts/build.sh), and the tests find the copy
// SwiftPM builds next to the test bundle. It imports nothing but Darwin.
let package = Package(
    name: "Pitbox",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Pitbox", targets: ["Pitbox"]),
        .executable(name: "pitbox-command-helper", targets: ["pitbox-command-helper"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0"),
    ],
    targets: [
        .target(name: "PitboxKit"),
        .target(name: "PitboxSessions", dependencies: ["PitboxKit"]),
        .target(name: "PitboxConsole", dependencies: [
            "PitboxKit",
            .product(name: "SwiftTerm", package: "SwiftTerm"),
        ]),
        .target(name: "PitboxGuard", dependencies: ["PitboxKit"]),
        .target(name: "PitboxShell", dependencies: ["PitboxKit"]),
        .target(name: "PitboxDock", dependencies: ["PitboxKit"]),
        .executableTarget(name: "pitbox-command-helper"),
        .executableTarget(name: "Pitbox", dependencies: [
            "PitboxKit", "PitboxSessions", "PitboxConsole", "PitboxGuard", "PitboxShell", "PitboxDock",
        ]),
        .testTarget(name: "PitboxKitTests", dependencies: ["PitboxKit"]),
        .testTarget(name: "PitboxSessionsTests", dependencies: ["PitboxSessions"]),
        .testTarget(name: "PitboxConsoleTests", dependencies: ["PitboxConsole", "pitbox-command-helper"]),
        .testTarget(name: "PitboxGuardTests", dependencies: ["PitboxGuard"]),
        .testTarget(name: "PitboxShellTests", dependencies: ["PitboxShell"]),
        .testTarget(name: "PitboxDockTests", dependencies: ["PitboxDock"]),
        .testTarget(name: "PitboxTests", dependencies: ["Pitbox"]),
    ],
    swiftLanguageModes: [.v5]
)
