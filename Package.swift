// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Clarishot",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Auto-updates (MIT licence).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "Clarishot",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Clarishot",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        // `clarishot` command-line tool and MCP server; bundled as Clarishot.app/Contents/Helpers/clarishot.
        .executableTarget(
            name: "ClarishotCLI",
            path: "Sources/ClarishotCLI"
        )
    ]
)
