import Foundation
import Testing

@testable import ClawProcess

/// The launcher is shared by the container sandbox and by host execution, so nothing in it may
/// name the container backend. Swift identifiers are mixed case; the screaming-snake environment
/// keys the runner deletes are ambient host variables, not symbols of this module.
@Suite struct ClawProcessModuleHygieneTests {
  @Test func moduleSourcesNameNoContainerSymbol() throws {
    // given
    let sources = try Self.moduleSourceFiles()

    // when
    let offenders = try sources.flatMap { url in
      try Self.offendingLines(in: url)
    }

    // then
    #expect(!sources.isEmpty)
    #expect(offenders.isEmpty, "container-specific symbols in ClawProcess: \(offenders)")
  }
}

private extension ClawProcessModuleHygieneTests {
  static let bannedSymbolFragment = "Container"

  static func moduleSourceFiles() throws -> [URL] {
    let directory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Sources/ClawProcess", isDirectory: true)

    return try FileManager.default
      .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "swift" }
  }

  static func offendingLines(in url: URL) throws -> [String] {
    try String(contentsOf: url, encoding: .utf8)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .enumerated()
      .filter { $0.element.contains(bannedSymbolFragment) }
      .map { "\(url.lastPathComponent):\($0.offset + 1)" }
  }
}
