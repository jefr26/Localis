// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Localis",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "Localis", path: "Sources/Localis")
    ],
    swiftLanguageModes: [.v5]
)
