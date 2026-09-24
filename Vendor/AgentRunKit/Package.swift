// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "AgentRunKit",
    platforms: [.macOS(.v15)],
    products: [.library(name: "AgentRunKit", targets: ["AgentRunKit"])],
    targets: [.target(name: "AgentRunKit")]
)
