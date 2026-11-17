// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StarDash",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "StarDash",
            path: "Sources/StarDash"
        )
    ]
)
