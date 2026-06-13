// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "container-primer",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(
            name: "container-primer",
            targets: ["container-primer"]
        )
    ],
    dependencies: [
        .package(path: "../containerization")
    ],
    targets: [
        .executableTarget(
            name: "container-primer",
            dependencies: [
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
            ]
        )
    ]
)
