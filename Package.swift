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
    .package(url: "https://github.com/apple/swift-log.git", from: "1.14.0"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.11.0"),
    .package(url: "https://github.com/swiftlang/swift-subprocess.git", exact: "0.5.0"),
  ],
  targets: [
    .target(
      name: "ClawCore",
      dependencies: [
        .product(name: "Crypto", package: "swift-crypto")
      ]
    ),
    .target(
      name: "ClawSecrets",
      dependencies: [
        "ClawCore",
        "ClawAuth",
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
        .product(name: "NIOFoundationCompat", package: "swift-nio"),
      ]
    ),
    .target(
      name: "ClawLLM",
      dependencies: [
        "ClawCore",
        "ClawAuth",
        .product(name: "Logging", package: "swift-log"),
      ],
      resources: [.copy("Pricing/Prices.json")]
    ),
    .target(
      name: "ClawAgent",
      dependencies: [
        "ClawCore",
        .product(name: "Logging", package: "swift-log"),
      ]
    ),
    .target(name: "ClawTools", dependencies: ["ClawCore"]),
    .target(
      name: "ClawExec",
      dependencies: [
        "ClawCore",
        .product(name: "Subprocess", package: "swift-subprocess"),
      ]
    ),
    .target(name: "ClawAuth", dependencies: ["ClawCore"]),
    .target(name: "ClawTestSupport", dependencies: ["ClawCore", "ClawTools"]),
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
        "ClawAgent", "ClawWorkspace", "ClawTools", "ClawExec", "ClawAuth",
        .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
        .product(name: "Logging", package: "swift-log"),
      ]
    ),
    .testTarget(name: "ClawCoreTests", dependencies: ["ClawCore", "ClawTestSupport"]),
    // `ClawSecrets` and `ClawGateway` are test-only: the auth workflow is proven against the real
    // secret preparer, credential store, and instance lock it will be composed with, while
    // production `ClawAuth` still depends on `ClawCore` alone.
    .testTarget(
      name: "ClawAuthTests",
      dependencies: ["ClawAuth", "ClawCore", "ClawSecrets", "ClawGateway", "ClawTestSupport"]
    ),
    .testTarget(
      name: "ClawSecretsTests",
      dependencies: [
        "ClawSecrets", "ClawCore", "ClawTestSupport",
        .product(name: "Crypto", package: "swift-crypto"),
      ]
    ),
    .testTarget(name: "ClawDataTests", dependencies: ["ClawData", "ClawCore", "ClawTestSupport"]),
    .testTarget(name: "ClawWorkspaceTests", dependencies: ["ClawWorkspace", "ClawCore"]),
    .testTarget(
      name: "ClawTelegramTests",
      dependencies: [
        "ClawTelegram",
        "ClawCore",
        "ClawTestSupport",
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOHTTP1", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
      ]
    ),
    .testTarget(
      name: "ClawLLMTests",
      dependencies: [
        "ClawLLM", "ClawCore", "ClawTestSupport",
        .product(name: "Logging", package: "swift-log"),
      ],
      // Read by absolute #filePath in ChatGPTResponsesSSEParserTests, never via Bundle.module,
      // so they stay on disk as plain sources rather than bundled resources.
      exclude: ["ChatGPT/Fixtures"]
    ),
    .testTarget(
      name: "ClawAgentTests",
      dependencies: [
        "ClawAgent", "ClawCore", "ClawWorkspace", "ClawTestSupport",
        .product(name: "Logging", package: "swift-log"),
      ]
    ),
    .testTarget(
      name: "ClawToolsTests",
      dependencies: ["ClawTools", "ClawCore", "ClawTestSupport"]
    ),
    .testTarget(name: "ClawExecTests", dependencies: ["ClawExec", "ClawCore"]),
    .testTarget(
      name: "ClawGatewayTests",
      dependencies: [
        "ClawGateway", "ClawCore", "ClawData", "ClawAgent", "ClawTelegram", "ClawWorkspace",
        "ClawTools", "ClawTestSupport",
        .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
        .product(name: "ServiceLifecycleTestKit", package: "swift-service-lifecycle"),
      ]
    ),
    // Composition-root tests: they reach into `clawd` to prove the wiring the executable owns — the
    // service-graph ordering and the fatal-exit boundary — against the real `ClawGateway` types.
    .testTarget(
      name: "ClawdCompositionTests",
      dependencies: [
        "clawd", "ClawGateway", "ClawAgent", "ClawTestSupport",
        "ClawCore", "ClawAuth", "ClawSecrets", "ClawLLM", "ClawData", "ClawTelegram",
        .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
        .product(name: "GRDB", package: "GRDB.swift"),
        .product(name: "Logging", package: "swift-log"),
      ]
    ),
  ]
)
