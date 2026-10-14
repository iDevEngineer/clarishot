// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Clarishot",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Clarishot",
            path: "Sources/Clarishot"
        ),
        // `clarishot` command-line tool and MCP server; bundled as Clarishot.app/Contents/Helpers/clarishot.
        .executableTarget(
            name: "ClarishotCLI",
            path: "Sources/ClarishotCLI"
        )
    ]
)
