// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TokenMonitor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TokenMonitor", targets: ["TokenMonitorApp"])
    ],
    targets: [
        .executableTarget(
            name: "TokenMonitorApp",
            path: "Sources/TokenMonitorApp"
        )
    ]
)
