import ClawTestSupport
import Foundation
import Testing

@testable import ClawEvaluation

extension EvaluationFilesystemSecurityTests {
  @Test func privateDirectoryPreparationRejectsALinkBeforeItCanChangeTheTarget() throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("outside", isDirectory: true)
    let link = root.appendingPathComponent("linked", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    // when
    let error = #expect(
      throws: EvaluationPathSecurityError.symlinkedComponent(link.lastPathComponent)
    ) {
      try EvaluationPathSecurity.ensurePrivateDirectory(at: link)
    }

    // then
    #expect(error != nil)
    let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o755)
  }

  @Test func privateDirectoryPreparationRejectsDotTraversalBeforeNormalization() throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let safe = root.appendingPathComponent("safe", isDirectory: true)
    let outside = root.appendingPathComponent("outside", isDirectory: true)
    let outsideChild = outside.appendingPathComponent("child", isDirectory: true)
    try FileManager.default.createDirectory(at: safe, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: outsideChild, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: outside.path)
    try FileManager.default.createSymbolicLink(
      at: safe.appendingPathComponent("link"),
      withDestinationURL: outsideChild
    )
    let raw = URL(fileURLWithPath: safe.appendingPathComponent("link/..").path)

    // when
    let error = #expect(throws: EvaluationPathSecurityError.dotPathComponent("..")) {
      try EvaluationPathSecurity.ensurePrivateDirectory(at: raw)
    }

    // then
    #expect(error != nil)
    let attributes = try FileManager.default.attributesOfItem(atPath: outside.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o755)
  }

  @Test func privateDirectoryPreparationAcceptsTheTrustedSystemTemporaryRoot() throws {
    // given
    let root = try makeTemporaryRoot(prefix: "claw-evaluation-path")
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("private", isDirectory: true)

    // when
    try EvaluationPathSecurity.ensurePrivateDirectory(at: directory)

    // then
    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
    #expect(isDirectory.boolValue)
    let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o700)
  }

  #if os(macOS)
    @Test func privateDirectoryPreparationTrustsOnlyTheCanonicalSystemTemporaryAlias() throws {
      // given
      let directoryName = "swift-claw-evaluation-path-\(UUID().uuidString)"
      let canonicalRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        .appendingPathComponent(directoryName, isDirectory: true)
      let aliasRoot = URL(fileURLWithPath: "/tmp", isDirectory: true)
        .appendingPathComponent(directoryName, isDirectory: true)
      defer { try? FileManager.default.removeItem(at: canonicalRoot) }

      // when
      try EvaluationPathSecurity.ensurePrivateDirectory(at: canonicalRoot)
      try EvaluationPathSecurity.ensurePrivateDirectory(at: aliasRoot)

      let target = canonicalRoot.appendingPathComponent("target", isDirectory: true)
      let link = canonicalRoot.appendingPathComponent("link", isDirectory: true)
      try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
      let aliasLink = aliasRoot.appendingPathComponent("link", isDirectory: true)

      // then
      #expect(
        throws: EvaluationPathSecurityError.symlinkedComponent(link.lastPathComponent)
      ) {
        try EvaluationPathSecurity.ensurePrivateDirectory(at: aliasLink)
      }
    }
  #endif

  @Test func workerConfigurationSnapshotRejectsDotComponentsBeforeNormalization() throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = root.appendingPathComponent("attempt.json")
    try Data("{}".utf8).write(to: configuration)
    let pathWithDotComponent =
      configuration.deletingLastPathComponent().path + "/./" + configuration.lastPathComponent

    // when
    let error = #expect(throws: EvaluationPathSecurityError.dotPathComponent(".")) {
      _ = try EvaluationWorkerConfigurationSnapshot.load(
        kind: .attempt,
        path: pathWithDotComponent
      )
    }

    // then
    #expect(error != nil)
  }

  @Test func durablePublicationRejectsLinksInTheDestinationPath() throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let outside = root.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
    let parentLink = root.appendingPathComponent("parent-link", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: parentLink, withDestinationURL: outside)
    let ancestorDestination = parentLink.appendingPathComponent("receipt.json")

    let leafTarget = root.appendingPathComponent("leaf-target.json")
    try Data("untouched".utf8).write(to: leafTarget)
    let leafDestination = root.appendingPathComponent("leaf-link.json")
    try FileManager.default.createSymbolicLink(at: leafDestination, withDestinationURL: leafTarget)

    // when
    let ancestorError = #expect(
      throws: EvaluationPathSecurityError.symlinkedComponent(parentLink.lastPathComponent)
    ) {
      try EvaluationDurablePublication.publish(Data("blocked".utf8), to: ancestorDestination)
    }
    let leafError = #expect(
      throws: EvaluationPathSecurityError.symlinkedComponent(leafDestination.lastPathComponent)
    ) {
      try EvaluationDurablePublication.publish(Data("blocked".utf8), to: leafDestination)
    }

    // then
    #expect(ancestorError != nil)
    #expect(leafError != nil)
    #expect(
      FileManager.default.fileExists(atPath: outside.appendingPathComponent("receipt.json").path)
        == false
    )
    #expect(try Data(contentsOf: leafTarget) == Data("untouched".utf8))
  }
}
