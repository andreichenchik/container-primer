// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentWrap",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(
            name: "agent-wrap",
            targets: ["AgentWrap"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/containerization", exact: "0.33.4"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
    ],
    targets: [
        .executableTarget(
            name: "AgentWrap",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
                .product(name: "ContainerizationArchive", package: "containerization"),
            ]
        ),
        .testTarget(
            name: "AgentWrapTests",
            dependencies: ["AgentWrap"]
        ),
    ]
)
