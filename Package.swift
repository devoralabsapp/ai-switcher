// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AISwitcher",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "AISwitcher", targets: ["AISwitcher"])],
    targets: [
        .target(name: "AISwitcherCore"),
        .executableTarget(name: "AISwitcher", dependencies: ["AISwitcherCore"]),
        .testTarget(name: "AISwitcherCoreTests", dependencies: ["AISwitcherCore"]),
    ]
)
