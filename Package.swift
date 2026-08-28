// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OwlCap",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "OwlCap",
            path: "Sources/OwlCap",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        )
    ]
)
