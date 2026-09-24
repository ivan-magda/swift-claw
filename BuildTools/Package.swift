// swift-tools-version: 6.4
import PackageDescription

let package = Package(
  name: "BuildTools",
  dependencies: [
    .package(url: "https://github.com/nicklockwood/SwiftFormat.git", exact: "0.62.1"),
  ]
)
