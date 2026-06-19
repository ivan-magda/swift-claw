import Foundation
import Testing

@testable import ClawGateway

@Suite struct InstanceLockTests {
  private func tempPath() -> String {
    NSTemporaryDirectory() + "claw-lock-\(UInt64.random(in: 0..<(.max))).lock"
  }

  @Test func acquiresWhenFree() throws {
    // given
    let path = tempPath()
    defer { try? FileManager.default.removeItem(atPath: path) }

    // when
    let lock = try InstanceLock(path: path)

    // then
    lock.release()
  }

  @Test func secondAcquireFails() throws {
    // given
    let path = tempPath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let first = try InstanceLock(path: path)
    defer { first.release() }

    // then
    #expect(throws: InstanceLock.LockError.alreadyLocked) {
      _ = try InstanceLock(path: path)
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
}
