// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Quill",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Quill",
            path: "Sources/Quill"
        )
    ]
)
