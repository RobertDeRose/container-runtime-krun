// swift-tools-version: 6.2

import PackageDescription

let containerRevision = "eee7ad097079cc3b02d5309ec10160143f2d0c6a"
let containerizationVersion = Version(0, 43, 0)
let grpcSwiftVersion = Version(2, 4, 3)
let swiftSystemVersion = Version(1, 8, 1)

let package = Package(
  name: "container-runtime-krun",
  platforms: [.macOS("15")],
  products: [
    .executable(name: "container-runtime-krun", targets: ["KrunRuntimePlugin"]),
    .executable(name: "container-krun-vmm-helper", targets: ["KrunVMMHelper"]),
    .library(name: "KrunRuntimeCore", targets: ["KrunRuntimeCore"]),
    .library(name: "KrunVMMProtocol", targets: ["KrunVMMProtocol"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/container.git", revision: containerRevision),
    .package(url: "https://github.com/apple/containerization.git", exact: containerizationVersion),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.7.0"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.10.1"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
    .package(url: "https://github.com/grpc/grpc-swift-2.git", exact: grpcSwiftVersion),
    .package(url: "https://github.com/apple/swift-system.git", exact: swiftSystemVersion),
  ],
  targets: [
    .target(name: "KrunVMMProtocol"),
    .target(
      name: "KrunRuntimeCore",
      dependencies: [
        "KrunVMMProtocol",
        .product(name: "ContainerNetworkClient", package: "container"),
        .product(name: "ContainerResource", package: "container"),
        .product(name: "SocketForwarder", package: "container"),
        .product(name: "ContainerRuntimeClient", package: "container"),
        .product(name: "ContainerXPC", package: "container"),
        .product(name: "Containerization", package: "containerization"),
        .product(name: "ContainerizationArchive", package: "containerization"),
        .product(name: "ContainerizationOCI", package: "containerization"),
        .product(name: "ContainerizationOS", package: "containerization"),
        .product(name: "Logging", package: "swift-log"),
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "GRPCCore", package: "grpc-swift-2"),
        .product(name: "SystemPackage", package: "swift-system"),
      ]
    ),
    .executableTarget(
      name: "KrunRuntimePlugin",
      dependencies: [
        "KrunRuntimeCore",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "ContainerLog", package: "container"),
        .product(name: "ContainerPlugin", package: "container"),
        .product(name: "ContainerRuntimeClient", package: "container"),
        .product(name: "ContainerXPC", package: "container"),
      ]
    ),
    .executableTarget(name: "KrunVMMHelper", dependencies: ["KrunVMMProtocol"]),
    .testTarget(
      name: "KrunVMMProtocolTests",
      dependencies: ["KrunVMMProtocol"]
    ),
    .testTarget(
      name: "KrunRuntimeCoreTests",
      dependencies: [
        "KrunRuntimeCore",
        "KrunVMMProtocol",
        .product(name: "ContainerResource", package: "container"),
        .product(name: "ContainerizationOCI", package: "containerization"),
        .product(name: "SystemPackage", package: "swift-system"),
      ]
    ),
  ]
)
