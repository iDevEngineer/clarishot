// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Snapzy",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Snapzy",
            path: "Sources/Snapzy"
        ),
        // `snapzy` command-line tool and MCP server; bundled as Snapzy.app/Contents/Helpers/snapzy.
        .executableTarget(
            name: "SnapzyCLI",
            path: "Sources/SnapzyCLI"
        )
    ]
)
