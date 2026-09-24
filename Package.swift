// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "HabitableCore",
    platforms: [.macOS(.v13)],
    dependencies: [.package(url: "https://github.com/SwiftyJSON/SwiftyJSON.git", exact: "5.0.2")],
    targets: [
        .target(name: "HabitableCore", dependencies: ["SwiftyJSON"], path: "Habitable/Models"),
        .testTarget(name: "HabitableCoreTests", dependencies: ["HabitableCore"])
    ],
    swiftLanguageModes: [.v5]
)
