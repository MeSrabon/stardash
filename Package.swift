// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StarDash",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Updates: Sparkle does the download, signature check and app swap. StarDash draws its own UI.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "StarDash",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/StarDash",
            // The app bundle keeps Sparkle in Contents/Frameworks; a plain `swift build` leaves it next to the binary.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                                           "-Xlinker", "-rpath", "-Xlinker", "@executable_path"])]
        )
    ]
)
