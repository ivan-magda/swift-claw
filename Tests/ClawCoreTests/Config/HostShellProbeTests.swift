import Foundation
import Testing

@testable import ClawCore

@Suite struct HostShellProbeTests {
  @Test func executableFileIsAvailable() {
    // given
    let shell = TemporaryShell(mode: 0o755)
    defer { shell.remove() }

    // when
    let availability = HostShellProbe.availability(shellPath: shell.path)

    // then
    #expect(availability == .available)
    #expect(availability.isAvailable)
  }

  @Test func missingFileNamesThePath() {
    // given
    let path = NSTemporaryDirectory() + "clawd-absent-shell-" + UUID().uuidString

    // when
    let availability = HostShellProbe.availability(shellPath: path)

    // then
    #expect(availability == .unavailable(reason: "no file at \(path)"))
    #expect(availability.isAvailable == false)
  }

  @Test func nonExecutableFileIsUnavailable() {
    // given
    let shell = TemporaryShell(mode: 0o644)
    defer { shell.remove() }

    // when
    let availability = HostShellProbe.availability(shellPath: shell.path)

    // then
    #expect(availability == .unavailable(reason: "\(shell.path) is not executable"))
  }

  @Test func directoryIsUnavailable() throws {
    // given
    let path = NSTemporaryDirectory() + "clawd-shell-dir-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: path) }

    // when
    let availability = HostShellProbe.availability(shellPath: path)

    // then
    #expect(availability == .unavailable(reason: "\(path) is a directory"))
  }
}

/// A real file on disk, since the probe's whole job is asking the filesystem.
private struct TemporaryShell {
  let path: String

  init(mode: Int) {
    path = NSTemporaryDirectory() + "clawd-shell-" + UUID().uuidString
    FileManager.default.createFile(
      atPath: path,
      contents: Data("#!/bin/sh\n".utf8),
      attributes: [.posixPermissions: NSNumber(value: mode)]
    )
  }

  func remove() {
    try? FileManager.default.removeItem(atPath: path)
  }
}
