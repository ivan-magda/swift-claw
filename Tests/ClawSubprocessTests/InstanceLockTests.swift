import Foundation
import Testing

@testable import ClawSubprocess

#if canImport(Glibc)
  import Glibc
#else
  import Darwin
#endif

@Suite struct InstanceLockTests {
  private func tempPath() -> String {
    NSTemporaryDirectory() + "claw-lock-\(UInt64.random(in: 0..<(.max))).lock"
  }

  @Test func secondAcquireFails() throws {
    // given
    let path = tempPath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let first = try InstanceLock(path: path)
    defer { first.release() }

    // when
    let second = Result { try InstanceLock(path: path) }

    // then
    #expect(throws: InstanceLock.LockError.alreadyLocked) {
      _ = try second.get()
    }
  }

  @Test func reacquiresAfterRelease() throws {
    // given
    let path = tempPath()
    defer { try? FileManager.default.removeItem(atPath: path) }

    // when
    let first = try InstanceLock(path: path)
    first.release()

    // then
    let second = try InstanceLock(path: path)
    second.release()
  }

  @Test func refusesToFollowALinkAtTheLockPath() throws {
    // given
    let path = tempPath()
    let target = path + ".target"
    defer {
      try? FileManager.default.removeItem(atPath: path)
      try? FileManager.default.removeItem(atPath: target)
    }
    try Data("unrelated".utf8).write(to: URL(fileURLWithPath: target))
    try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)

    // when
    let acquisition = Result { try InstanceLock(path: path) }

    // then
    #expect(throws: InstanceLock.LockError.insecureLockFile) {
      _ = try acquisition.get()
    }
    #expect(try Data(contentsOf: URL(fileURLWithPath: target)) == Data("unrelated".utf8))
  }

  @Test func normalizesAnOwnedLockFileToOwnerOnlyPermissions() throws {
    // given
    let path = tempPath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let url = URL(fileURLWithPath: path)
    try Data().write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)

    // when
    let lock = try InstanceLock(path: path)
    defer { lock.release() }

    // then
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o600)
  }

  @Test func refusesAHardLinkedLockWithoutChangingItsTarget() throws {
    // given
    let path = tempPath()
    let target = path + ".target"
    defer {
      try? FileManager.default.removeItem(atPath: path)
      try? FileManager.default.removeItem(atPath: target)
    }
    let contents = Data("unrelated".utf8)
    try contents.write(to: URL(fileURLWithPath: target))
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target)
    try FileManager.default.linkItem(
      at: URL(fileURLWithPath: target),
      to: URL(fileURLWithPath: path)
    )

    // when
    let acquisition = Result { try InstanceLock(path: path) }

    // then
    #expect(throws: InstanceLock.LockError.insecureLockFile) {
      _ = try acquisition.get()
    }
    let attributes = try FileManager.default.attributesOfItem(atPath: target)
    #expect((attributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o755)
    #expect(try Data(contentsOf: URL(fileURLWithPath: target)) == contents)
  }

  @Test func refusesANonRegularLockEntry() throws {
    // given
    let path = tempPath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    try #require(mkfifo(path, 0o600) == 0)

    // when
    let acquisition = Result { try InstanceLock(path: path) }

    // then
    #expect(throws: InstanceLock.LockError.insecureLockFile) {
      _ = try acquisition.get()
    }
  }
}
