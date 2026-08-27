// swift-tools-version: 6.1
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
    .package(url: "https://github.com/modelcontextprotocol/swift-sdk", from: "0.12.1"),
    // Transitive through the MCP SDK. Declared here only to switch its "AsyncHTTPClient"
    // trait on: the trait is off by default, yet the module is visible in our build (we
    // depend on AsyncHTTPClient directly), so its `canImport` guard compiles code against
    // a dependency the target never declared and the module search path breaks.
    .package(
      url: "https://github.com/mattt/eventsource.git",
      from: "1.4.1",
      traits: ["AsyncHTTPClient"]
    ),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.14.0"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.11.0"),
    .package(url: "https://github.com/swiftlang/swift-subprocess.git", exact: "1.0.0"),
    .package(url: "https://github.com/apple/swift-system.git", from: "1.7.4"),
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
      name: "ClawHTTP",
      dependencies: [
        "ClawCore",
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOFoundationCompat", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
      ]
    ),
    .target(
      name: "ClawTelegram",
      dependencies: [
        "ClawCore", "ClawHTTP",
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
      ]
    ),
    .target(
      name: "ClawLLM",
      dependencies: [
        "ClawCore",
        "ClawAuth",
        .product(name: "Logging", package: "swift-log"),
      ],
      resources: [.embedInCode("Pricing/Prices.json")]
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
      name: "ClawMCP",
      dependencies: [
        "ClawCore",
        .product(name: "Logging", package: "swift-log"),
        .product(name: "MCP", package: "swift-sdk"),
      ]
    ),
    .target(name: "ClawAppleSpeech", dependencies: ["ClawCore"]),
    .target(
      name: "ClawSubprocess",
      dependencies: [
        "ClawCore",
        .product(name: "Subprocess", package: "swift-subprocess"),
        .product(
          name: "SystemPackage",
          package: "swift-system",
          condition: .when(platforms: [.linux])
        ),
      ]
    ),
    .target(
      name: "ClawExec",
      dependencies: [
        "ClawCore", "ClawSubprocess",
      ]
    ),
    .target(name: "ClawAuth", dependencies: ["ClawCore"]),
    .target(
      name: "ClawTestSupport",
      dependencies: [
        "ClawCore", "ClawTools",
        .product(name: "Logging", package: "swift-log"),
      ]
    ),
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
        "ClawCore", "ClawData", "ClawSecrets", "ClawHTTP", "ClawTelegram", "ClawGateway", "ClawLLM",
        "ClawAgent", "ClawWorkspace", "ClawTools", "ClawExec", "ClawSubprocess", "ClawAuth",
        "ClawAppleSpeech",
        "ClawMCP",
        .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
        .product(name: "Logging", package: "swift-log"),
      ]
    ),
    .testTarget(name: "ClawCoreTests", dependencies: ["ClawCore", "ClawTestSupport"]),
    .testTarget(
      name: "ClawAuthTests",
      dependencies: [
        "ClawAuth", "ClawCore", "ClawSecrets", "ClawGateway", "ClawSubprocess", "ClawTestSupport",
      ]
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
      name: "ClawHTTPTests",
      dependencies: [
        "ClawHTTP", "ClawCore", "ClawTestSupport",
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOHTTP1", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
      ]
    ),
    .testTarget(
      name: "ClawTelegramTests",
      dependencies: [
        "ClawTelegram", "ClawHTTP",
        "ClawCore",
        "ClawTestSupport",
      ]
    ),
    .testTarget(
      name: "ClawLLMTests",
      dependencies: [
        "ClawLLM", "ClawCore", "ClawTestSupport",
        .product(name: "Logging", package: "swift-log"),
      ],
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
    .testTarget(
      name: "ClawMCPTests",
      dependencies: [
        "ClawMCP", "ClawCore", "ClawTestSupport",
        .product(name: "MCP", package: "swift-sdk"),
      ]
    ),
    .testTarget(
      name: "ClawExecTests",
      dependencies: ["ClawExec", "ClawCore", "ClawSubprocess"]
    ),
    .testTarget(
      name: "ClawSubprocessTests",
      dependencies: ["ClawSubprocess", "ClawTestSupport"]
    ),
    .testTarget(
      name: "ClawAppleSpeechTests",
      dependencies: ["ClawAppleSpeech", "ClawCore"],
      resources: [.copy("Fixtures")]
    ),
    .testTarget(
      name: "ClawGatewayTests",
      dependencies: [
        "ClawGateway", "ClawCore", "ClawData", "ClawAgent", "ClawTelegram", "ClawWorkspace",
        "ClawTools", "ClawTestSupport",
        .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
        .product(name: "ServiceLifecycleTestKit", package: "swift-service-lifecycle"),
      ]
    ),
    .testTarget(
      name: "ClawdCompositionTests",
      dependencies: [
        "clawd", "ClawGateway", "ClawAgent", "ClawHTTP", "ClawTestSupport",
        "ClawCore", "ClawAuth", "ClawSecrets", "ClawLLM", "ClawData", "ClawTelegram",
        "ClawWorkspace", "ClawMCP", "ClawSubprocess", "ClawTools",
        .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
        .product(name: "ServiceLifecycleTestKit", package: "swift-service-lifecycle"),
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
        .product(name: "GRDB", package: "GRDB.swift"),
        .product(name: "Logging", package: "swift-log"),
      ]
    ),
  ]
)
