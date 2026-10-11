// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TokenBar",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "TokenBar", targets: ["TokenBar"])],
    targets: [
        .target(name: "TokenBarWidgetShared", path: "Shared"),
        .executableTarget(name: "TokenBar", dependencies: ["TokenBarWidgetShared"]),
        .testTarget(name: "TokenBarTests", dependencies: ["TokenBar", "TokenBarWidgetShared"])
    ]
)
