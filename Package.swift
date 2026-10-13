// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Snapzy",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Snapzy",
            path: "Sources/Snapzy"
        )
    ]
)
