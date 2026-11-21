// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "GrafanaAlerts",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "GrafanaAlerts", targets: ["GrafanaAlerts"]),
    ],
    targets: [
        .executableTarget(
            name: "GrafanaAlerts",
            path: "Sources/GrafanaAlerts"
        ),
    ]
)
