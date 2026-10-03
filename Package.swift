// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "HabitableCore",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/SwiftyJSON/SwiftyJSON.git", exact: "5.0.2"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1")
    ],
    targets: [
        .target(name: "HabitableCore", dependencies: ["SwiftyJSON", .product(name: "MCP", package: "swift-sdk")], path: "Habitable/Models"),
        .testTarget(name: "HabitableCoreTests", dependencies: ["HabitableCore"], resources: [.copy("Fixtures")])
    ],
    swiftLanguageModes: [.v6]
)
