// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TokenBar",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "TokenBar", targets: ["TokenBar"])],
    targets: [
        .executableTarget(name: "TokenBar"),
        .testTarget(name: "TokenBarTests", dependencies: ["TokenBar"])
    ]
)
