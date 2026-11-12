// swift-tools-version: 6.4
import PackageDescription

let package = Package(
  name: "BuildTools",
  dependencies: [
    .package(url: "https://github.com/nicklockwood/SwiftFormat.git", exact: "0.64.5"),
    .package(url: "https://github.com/ivan-magda/swift-dead-code.git", exact: "0.1.3"),
  ]
)
