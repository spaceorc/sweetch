// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "sweetch",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "sweetch",
            path: "Sources/sweetch",
            exclude: ["Info.plist"]
        )
    ]
)
