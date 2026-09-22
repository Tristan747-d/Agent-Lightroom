// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentLightroom",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "AgentLightroom", targets: ["AgentLightroom"])],
    targets: [.executableTarget(name: "AgentLightroom")]
)
