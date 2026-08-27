import ClawCore
import Foundation
import Testing

@testable import ClawEvaluation

#if canImport(Glibc)
  import Glibc
#else
  import Darwin
#endif

extension EvaluationFilesystemSecurityTests {
  @Test func restartLockProbeRejectsALinkedStateRootBeforeCreatingALock() throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let outside = root.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
    let linkedState = root.appendingPathComponent("linked-state", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: linkedState, withDestinationURL: outside)

    // when
    let error = #expect(
      throws: EvaluationPathSecurityError.symlinkedComponent(linkedState.lastPathComponent)
    ) {
      _ = try EvaluationWorkerLifecycle.proveProductionLockIsFree(stateRoot: linkedState)
    }

    // then
    #expect(error != nil)
    #expect(
      FileManager.default.fileExists(
        atPath: outside.appendingPathComponent("clawd.lock").path
      ) == false
    )
  }

  @Test func promotedLessonInstallationRejectsAMatchingSymlinkAtImmutablePath() throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let stateRoot = root.appendingPathComponent("state", isDirectory: true)
    let sets = stateRoot.appendingPathComponent(
      PageEvaluationContract.lessonSetsDirectoryName,
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: sets, withIntermediateDirectories: true)
    let promotion = try makeEvaluationPromotionFixture()
    let lesson = promotion.activeLessonData
    let digest = SHA256Digest.hex(lesson)
    let external = root.appendingPathComponent("external.json")
    try lesson.write(to: external)
    let immutable = sets.appendingPathComponent("\(digest).json")
    try FileManager.default.createSymbolicLink(at: immutable, withDestinationURL: external)

    // when
    let error = #expect(
      throws: EvaluationPathSecurityError.symlinkedComponent(immutable.lastPathComponent)
    ) {
      _ = try EvaluationWorkspaceMaterializer.installPromotedLessonSet(
        lesson,
        receipt: promotion.receipt,
        stateRoot: stateRoot
      )
    }

    // then
    #expect(error != nil)
    #expect(try Data(contentsOf: external) == lesson)
  }

  @Test(arguments: ["hardlink", "fifo"])
  func promotedLessonInstallationRejectsUnsafeExistingEntries(_ entryKind: String) throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let stateRoot = root.appendingPathComponent("state", isDirectory: true)
    let sets = stateRoot.appendingPathComponent(
      PageEvaluationContract.lessonSetsDirectoryName,
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: sets, withIntermediateDirectories: true)
    let promotion = try makeEvaluationPromotionFixture()
    let lesson = promotion.activeLessonData
    let digest = SHA256Digest.hex(lesson)
    let immutable = sets.appendingPathComponent("\(digest).json")
    let external = root.appendingPathComponent("external.json")
    try lesson.write(to: external)
    switch entryKind {
    case "hardlink":
      try FileManager.default.linkItem(at: external, to: immutable)
    case "fifo":
      #expect(mkfifo(immutable.path, S_IRUSR | S_IWUSR) == 0)
    default:
      Issue.record("Unknown entry kind \(entryKind)")
    }

    // when
    let error = #expect(
      throws: EvaluationPathSecurityError.insecureFile(immutable.lastPathComponent)
    ) {
      _ = try EvaluationWorkspaceMaterializer.installPromotedLessonSet(
        lesson,
        receipt: promotion.receipt,
        stateRoot: stateRoot
      )
    }

    // then
    // The existing-entry idempotence branch may read only a private regular inode.
    #expect(error != nil)
    #expect(try Data(contentsOf: external) == lesson)
  }
}
