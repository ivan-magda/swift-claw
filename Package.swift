// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "swift-claw",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "clawd", targets: ["clawd"])
  ],
  dependencies: [
    .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.0"),
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.0"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.11.0"),
  ],
  targets: [
    .target(name: "ClawCore"),
    .target(
      name: "ClawData",
      dependencies: [
        "ClawCore",
        .product(name: "GRDB", package: "GRDB.swift"),
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
      dependencies: ["ClawCore"],
      resources: [.copy("Prices.json")]
    ),
    .target(name: "ClawAgent", dependencies: ["ClawCore"]),
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
        "ClawCore", "ClawData", "ClawTelegram", "ClawGateway", "ClawLLM", "ClawAgent",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
        .product(name: "Logging", package: "swift-log"),
      ]
    ),
    .testTarget(name: "ClawCoreTests", dependencies: ["ClawCore"]),
    .testTarget(name: "ClawDataTests", dependencies: ["ClawData", "ClawCore"]),
    .testTarget(name: "ClawTelegramTests", dependencies: ["ClawTelegram", "ClawCore"]),
    .testTarget(name: "ClawLLMTests", dependencies: ["ClawLLM", "ClawCore"]),
    .testTarget(name: "ClawAgentTests", dependencies: ["ClawAgent", "ClawCore"]),
    .testTarget(
      name: "ClawGatewayTests",
      dependencies: ["ClawGateway", "ClawCore", "ClawData", "ClawAgent"]
    ),
  ]
)
