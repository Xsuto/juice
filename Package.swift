// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Juice",
    platforms: [.macOS("27.0")],
    targets: [
        .executableTarget(
            name: "Juice",
            path: "Sources/Juice"
        )
    ]
)
