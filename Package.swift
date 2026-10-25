// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AISwitcher",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "AISwitcher", targets: ["AISwitcher"])],
    targets: [
        .target(name: "AISwitcherCore", resources: [.process("Resources")]),
        .executableTarget(name: "AISwitcher", dependencies: ["AISwitcherCore"]),
        .testTarget(name: "AISwitcherCoreTests", dependencies: ["AISwitcherCore", "AISwitcher"], resources: [.copy("Fixtures")]),
    ]
)
