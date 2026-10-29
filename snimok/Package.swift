// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Snimok",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Snimok",
            path: "Sources/Snimok",
            linkerSettings: [.linkedFramework("Carbon")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
