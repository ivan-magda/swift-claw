import ClawAgent
import ClawCore
import ClawSubprocess
import ClawTestSupport
import Foundation
import Synchronization
import Testing

@testable import ClawEvaluation
@testable import ClawSecrets

@Suite struct EvaluationWorkspaceTests {
  @Test func workspaceResetLeavesOnlyTheVerifiedInput() throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configured = try makeEvaluationConfiguration(root: root)
    try FileManager.default.createDirectory(
      at: configured.configuration.workspaceRootURL,
      withIntermediateDirectories: true
    )
    try Data("stale".utf8).write(
      to: configured.configuration.workspaceRootURL.appendingPathComponent("stale.txt")
    )

    // when
    let materialized = try EvaluationWorkspaceMaterializer.reset(
      configuration: configured.configuration
    )

    // then
    #expect(materialized.inputSHA256 == configured.configuration.inputSHA256)
    #expect(
      try FileManager.default.contentsOfDirectory(
        atPath: configured.configuration.workspaceRootURL.path
      ) == [PageEvaluationContract.inputFileName]
    )
  }

  @Test func publishedLessonArtifactIsReloadedIntoAFreshWorkspaceMaterialization() throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configurations = try makeEvaluationLessonReloadConfigurations(root: root)

    // when
    let first = try EvaluationWorkspaceMaterializer.reset(
      configuration: configurations.artifact
    )
    let stale = configurations.artifact.workspaceRootURL.appendingPathComponent("stale.txt")
    try Data("stale".utf8).write(to: stale)
    let restarted = try EvaluationWorkspaceMaterializer.reset(
      configuration: configurations.durable
    )

    // then
    #expect(first.lessonSetDigest == restarted.lessonSetDigest)
    #expect(first.lessonSetID == "candidate")
    #expect(restarted.lessonIDs == ["ignore-counters"])
    #expect(first.inputSHA256 == restarted.inputSHA256)
    #expect(restarted.lessonSource == .durableActive)
    #expect(restarted.lessonSetPath?.contains("/state/lesson-sets/") == true)
    #expect(FileManager.default.fileExists(atPath: stale.path) == false)
  }

  @Test(arguments: ["active-pointer", "immutable-artifact"])
  func durableLessonReloadRejectsMutatedSelectionEvidence(_ mutation: String) throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configurations = try makeEvaluationLessonReloadConfigurations(root: root)
    let published = try EvaluationWorkspaceMaterializer.reset(
      configuration: configurations.artifact
    )
    let stateRoot = configurations.artifact.stateRootURL
    switch mutation {
    case "active-pointer":
      try Data(#"{"schema_version":1}"#.utf8).write(
        to: stateRoot.appendingPathComponent(PageEvaluationContract.activeLessonFileName)
      )
    case "immutable-artifact":
      let immutable =
        stateRoot
        .appendingPathComponent(PageEvaluationContract.lessonSetsDirectoryName, isDirectory: true)
        .appendingPathComponent("\(published.lessonSetDigest).json")
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: immutable.path
      )
      try Data("tampered".utf8).write(to: immutable)
    default:
      Issue.record("Unknown mutation \(mutation)")
    }

    // when
    let error = #expect(throws: EvaluationWorkspaceError.self) {
      _ = try EvaluationWorkspaceMaterializer.reset(configuration: configurations.durable)
    }

    // then — a fresh materialization must revalidate both layers from durable storage.
    #expect(error != nil)
  }

  @Test func uncertainEvaluationPublicationSurfacesAfterTheCommittedNameCannotBeSynced() throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("receipt.json")
    let intended = Data("durable-receipt".utf8)
    let publisher = SecureFilePublisher(
      failpoint: SecureFilePublisher.Failpoint(.directorySync, on: destination.lastPathComponent)
    )

    // when
    let error = #expect(
      throws: EvaluationDurablePublicationError.commitUncertain(destination.lastPathComponent)
    ) {
      try EvaluationDurablePublication.publish(intended, to: destination, publisher: publisher)
    }

    // then — the target name landed, but the harness refuses to report a durable write.
    #expect(error != nil)
    #expect(try Data(contentsOf: destination) == intended)
  }
}
