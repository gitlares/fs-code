// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "FSCode",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "FSCode", targets: ["FSCode"])],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.0"),
        .package(path: "Vendor/AgentRunKit")
    ],
    targets: [
        .target(name: "ProjectLibrary"),
        .target(name: "EditorCore"),
        .target(name: "AgentContextCore"),
        .target(name: "AgentConnectionCore", dependencies: [.product(name: "AgentRunKit", package: "AgentRunKit")]),
        .executableTarget(name: "FSCode", dependencies: ["ProjectLibrary", "EditorCore", "AgentContextCore", "AgentConnectionCore", .product(name: "SwiftTerm", package: "SwiftTerm"), .product(name: "Sparkle", package: "Sparkle")]),
        .testTarget(name: "ProjectLibraryTests", dependencies: ["ProjectLibrary"]),
        .testTarget(name: "EditorCoreTests", dependencies: ["EditorCore"]),
        .testTarget(name: "FSCodeTests", dependencies: ["FSCode"]),
        .testTarget(name: "AgentContextCoreTests", dependencies: ["AgentContextCore"]),
        .testTarget(name: "AgentConnectionCoreTests", dependencies: ["AgentConnectionCore"])
    ],
    swiftLanguageModes: [.v6]
)
