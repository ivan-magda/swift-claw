// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "swift-claw",
  platforms: [.macOS(.v15)],
  products: [
    .executable(name: "clawd", targets: ["clawd"])
  ],
  dependencies: [
    .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.0"),
    .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.0"),
    .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.2"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.11.0"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.11.0"),
  ],
  targets: [
    .target(name: "ClawCore"),
    .target(
      name: "ClawSecrets",
      dependencies: [
        "ClawCore",
        .product(name: "Crypto", package: "swift-crypto"),
      ]
    ),
    .target(
      name: "ClawData",
      dependencies: [
        "ClawCore",
        .product(name: "GRDB", package: "GRDB.swift"),
      ]
    ),
    .target(
      name: "ClawWorkspace",
      dependencies: [
        "ClawCore",
        .product(name: "Yams", package: "Yams"),
      ]
    ),
    .target(
      name: "ClawTelegram",
      dependencies: [
        "ClawCore",
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
        .product(name: "NIOCore", package: "swift-nio"),
      ]
    ),
    .target(
      name: "ClawLLM",
      dependencies: [
        "ClawCore",
        .product(name: "Logging", package: "swift-log"),
      ],
      resources: [.copy("Pricing/Prices.json")]
    ),
    .target(
      name: "ClawAgent",
      dependencies: [
        "ClawCore",
        "ClawWorkspace",
        .product(name: "Logging", package: "swift-log"),
      ]
    ),
    .target(name: "ClawTools", dependencies: ["ClawCore"]),
    .target(
      name: "ClawGateway",
      dependencies: [
        "ClawCore",
        "ClawAgent",
        .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
        .product(name: "UnixSignals", package: "swift-service-lifecycle"),
        .product(name: "Logging", package: "swift-log"),
      ]
    ),
    .executableTarget(
      name: "clawd",
      dependencies: [
        "ClawCore", "ClawData", "ClawSecrets", "ClawTelegram", "ClawGateway", "ClawLLM",
        "ClawAgent", "ClawWorkspace", "ClawTools",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
        .product(name: "Logging", package: "swift-log"),
      ]
    ),
    .testTarget(name: "ClawCoreTests", dependencies: ["ClawCore"]),
    .testTarget(
      name: "ClawSecretsTests",
      dependencies: [
        "ClawSecrets", "ClawCore",
        .product(name: "Crypto", package: "swift-crypto"),
      ]
    ),
    .testTarget(name: "ClawDataTests", dependencies: ["ClawData", "ClawCore"]),
    .testTarget(name: "ClawWorkspaceTests", dependencies: ["ClawWorkspace", "ClawCore"]),
    .testTarget(
      name: "ClawTelegramTests",
      dependencies: [
        "ClawTelegram",
        "ClawCore",
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOHTTP1", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
      ]
    ),
    .testTarget(
      name: "ClawLLMTests",
      dependencies: [
        "ClawLLM", "ClawCore",
        .product(name: "Logging", package: "swift-log"),
      ]
    ),
    .testTarget(
      name: "ClawAgentTests",
      dependencies: [
        "ClawAgent", "ClawCore", "ClawWorkspace",
        .product(name: "Logging", package: "swift-log"),
      ]
    ),
    .testTarget(name: "ClawToolsTests", dependencies: ["ClawTools", "ClawCore"]),
    .testTarget(
      name: "ClawGatewayTests",
      dependencies: [
        "ClawGateway", "ClawCore", "ClawData", "ClawAgent", "ClawTelegram", "ClawWorkspace",
        "ClawTools",
      ]
    ),
  ]
)
