import ClawCore
import ClawSecrets
import Foundation

typealias EvaluationCanonicalJSON = CanonicalJSON

struct EvaluationCarrierReceipt: Codable, Sendable, Equatable {
  package let sourceSHA256: String
  package let taskID: String
  package let lessonSource: EvaluationLessonSource
  package let lessonSetSHA256: String
  package let lessonSetID: String
  package let lessonIDs: [String]
  package let inputSHA256: String
  package let promotionReceiptSHA256: String?

  package init(
    sourceSHA256: String,
    taskID: String,
    lessonSource: EvaluationLessonSource,
    lessonSetSHA256: String,
    lessonSetID: String,
    lessonIDs: [String],
    inputSHA256: String,
    promotionReceiptSHA256: String? = nil
  ) {
    self.sourceSHA256 = sourceSHA256
    self.taskID = taskID
    self.lessonSource = lessonSource
    self.lessonSetSHA256 = lessonSetSHA256
    self.lessonSetID = lessonSetID
    self.lessonIDs = lessonIDs
    self.inputSHA256 = inputSHA256
    self.promotionReceiptSHA256 = promotionReceiptSHA256
  }

  enum CodingKeys: String, CodingKey {
    case sourceSHA256 = "source_sha256"
    case taskID = "task_id"
    case lessonSource = "lesson_source"
    case lessonSetSHA256 = "lesson_set_sha256"
    case lessonSetID = "lesson_set_id"
    case lessonIDs = "lesson_ids"
    case inputSHA256 = "input_sha256"
    case promotionReceiptSHA256 = "promotion_receipt_sha256"
  }
}

struct EvaluationWorkspaceMaterialization: Codable, Sendable, Equatable {
  package let workspaceWasEmptyAtStart: Bool
  package let inputWasRegenerated: Bool
  package let inputPath: String
  package let inputSHA256: String
  package let inputByteCount: Int
  package let sourceArtifactPath: String
  package let sourceSHA256: String
  package let taskID: String
  package let lessonSource: EvaluationLessonSource
  package let lessonSetPath: String?
  package let lessonSetDigest: String
  package let lessonSetID: String
  package let lessonIDs: [String]
  package let carrierReceipt: EvaluationCarrierReceipt
  package let carrierReceiptSHA256: String

  package init(
    workspaceWasEmptyAtStart: Bool,
    inputWasRegenerated: Bool,
    inputPath: String,
    inputSHA256: String,
    inputByteCount: Int,
    sourceArtifactPath: String,
    sourceSHA256: String,
    taskID: String,
    lessonSource: EvaluationLessonSource,
    lessonSetPath: String?,
    lessonSetDigest: String,
    lessonSetID: String,
    lessonIDs: [String],
    carrierReceipt: EvaluationCarrierReceipt,
    carrierReceiptSHA256: String
  ) {
    self.workspaceWasEmptyAtStart = workspaceWasEmptyAtStart
    self.inputWasRegenerated = inputWasRegenerated
    self.inputPath = inputPath
    self.inputSHA256 = inputSHA256
    self.inputByteCount = inputByteCount
    self.sourceArtifactPath = sourceArtifactPath
    self.sourceSHA256 = sourceSHA256
    self.taskID = taskID
    self.lessonSource = lessonSource
    self.lessonSetPath = lessonSetPath
    self.lessonSetDigest = lessonSetDigest
    self.lessonSetID = lessonSetID
    self.lessonIDs = lessonIDs
    self.carrierReceipt = carrierReceipt
    self.carrierReceiptSHA256 = carrierReceiptSHA256
  }

  enum CodingKeys: String, CodingKey {
    case workspaceWasEmptyAtStart = "workspace_was_empty_at_start"
    case inputWasRegenerated = "input_was_regenerated"
    case inputPath = "input_path"
    case inputSHA256 = "input_sha256"
    case inputByteCount = "input_byte_count"
    case sourceArtifactPath = "source_artifact_path"
    case sourceSHA256 = "source_sha256"
    case taskID = "task_id"
    case lessonSource = "lesson_source"
    case lessonSetPath = "lesson_set_path"
    case lessonSetDigest = "lesson_set_digest"
    case lessonSetID = "lesson_set_id"
    case lessonIDs = "lesson_ids"
    case carrierReceipt = "carrier_receipt"
    case carrierReceiptSHA256 = "carrier_receipt_sha256"
  }
}

struct EvaluationActiveLessonPointer: Codable, Sendable, Equatable {
  package let schemaVersion: Int
  package let lessonSetID: String
  package let lessonSetSHA256: String

  package init(schemaVersion: Int = 1, lessonSetID: String, lessonSetSHA256: String) {
    self.schemaVersion = schemaVersion
    self.lessonSetID = lessonSetID
    self.lessonSetSHA256 = lessonSetSHA256
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case lessonSetID = "lesson_set_id"
    case lessonSetSHA256 = "lesson_set_sha256"
  }
}

enum EvaluationWorkspaceMaterializer {
  package static func reset(
    configuration: EvaluationAttemptConfiguration,
    fileManager: FileManager = .default
  ) throws -> EvaluationWorkspaceMaterialization {
    try configuration.validate()

    let workspace = configuration.workspaceRootURL
    let source = URL(fileURLWithPath: configuration.sourceArtifactPath).standardizedFileURL
    let optionalLesson = configuration.lessonArtifactPath.map {
      URL(fileURLWithPath: $0).standardizedFileURL
    }
    try EvaluationPathSecurity.rejectSymlinkComponents(
      in: [configuration.evaluationRootURL, configuration.stateRootURL, workspace, source]
        + [optionalLesson].compactMap { $0 }
    )
    guard EvaluationPathSecurity.isStrictlyContained(source, under: workspace) == false else {
      throw EvaluationWorkspaceError.sourceArtifactInsideWorkspace
    }
    if let optionalLesson,
      EvaluationPathSecurity.isStrictlyContained(optionalLesson, under: workspace)
    {
      throw EvaluationWorkspaceError.lessonArtifactInsideWorkspace
    }

    let sourceData = try EvaluationPathSecurity.readRegularSingleLinkFile(at: source)
    let observedSourceDigest = SHA256Digest.hex(sourceData)
    guard observedSourceDigest == configuration.sourceSHA256 else {
      throw EvaluationWorkspaceError.sourceDigestMismatch(
        expected: configuration.sourceSHA256,
        observed: observedSourceDigest
      )
    }
    if configuration.stage == EvaluationPageStage.synthesis.rawValue {
      return try resetSynthesis(
        configuration: configuration,
        workspace: workspace,
        source: source,
        sourceData: sourceData,
        sourceDigest: observedSourceDigest,
        fileManager: fileManager
      )
    }
    let sourceObject = try object(from: sourceData, source: true)
    guard
      Set(sourceObject.keys)
        == Set(["schema_version", "fixture_id", "task_id", "family_id", "split", "task"]),
      CanonicalJSON.integer(sourceObject["schema_version"]) == 1,
      sourceObject["fixture_id"] as? String == configuration.fixtureID,
      sourceObject["task_id"] as? String == configuration.taskID,
      let task = sourceObject["task"] as? [String: Any]
    else {
      throw EvaluationWorkspaceError.invalidSourceArtifact
    }

    let lesson = try resolveLessonSet(
      configuration: configuration,
      fileManager: fileManager
    )
    let carrier: [String: Any] = [
      "active_lessons": lesson.object,
      "schema_version": 1,
      "task": task,
      "task_id": configuration.taskID,
    ]
    let input = try canonicalJSONData(carrier)
    let digest = SHA256Digest.hex(input)
    guard digest == configuration.inputSHA256 else {
      throw EvaluationWorkspaceError.inputDigestMismatch(
        expected: configuration.inputSHA256,
        observed: digest
      )
    }
    guard let inputText = String(data: input, encoding: .utf8) else {
      throw EvaluationWorkspaceError.inputIsNotUTF8
    }
    guard inputText.count <= PageEvaluationContract.maximumInputGraphemes else {
      throw EvaluationWorkspaceError.inputGraphemeLimitExceeded(inputText.count)
    }

    let workspaceWasEmptyAtStart = try resetWorkspace(at: workspace, fileManager: fileManager)

    let destination = workspace.appendingPathComponent(PageEvaluationContract.inputFileName)
    try durableReplace(input, at: destination)

    let finalNames = try fileManager.contentsOfDirectory(atPath: workspace.path).sorted()
    guard finalNames == [PageEvaluationContract.inputFileName] else {
      throw EvaluationWorkspaceError.unexpectedWorkspaceContents(finalNames)
    }

    let resolvedLessonSetID = lessonSetID(in: lesson.object) ?? ""
    let resolvedLessonIDs = lessonIDs(in: lesson.object)
    let receipt = EvaluationCarrierReceipt(
      sourceSHA256: observedSourceDigest,
      taskID: configuration.taskID,
      lessonSource: configuration.lessonSource,
      lessonSetSHA256: lesson.digest,
      lessonSetID: resolvedLessonSetID,
      lessonIDs: resolvedLessonIDs,
      inputSHA256: digest,
      promotionReceiptSHA256: configuration.promotionReceiptSHA256
    )
    let receiptData = try canonicalJSONData(receipt)
    return EvaluationWorkspaceMaterialization(
      workspaceWasEmptyAtStart: workspaceWasEmptyAtStart,
      inputWasRegenerated: true,
      inputPath: destination.path,
      inputSHA256: digest,
      inputByteCount: input.count,
      sourceArtifactPath: source.path,
      sourceSHA256: observedSourceDigest,
      taskID: configuration.taskID,
      lessonSource: configuration.lessonSource,
      lessonSetPath: lesson.path?.path,
      lessonSetDigest: lesson.digest,
      lessonSetID: resolvedLessonSetID,
      lessonIDs: resolvedLessonIDs,
      carrierReceipt: receipt,
      carrierReceiptSHA256: SHA256Digest.hex(receiptData)
    )
  }

  /// Installs a deterministically promoted lesson set at its immutable content-addressed path
  /// without selecting it as active. Regression and pre-restart attempts read this exact artifact;
  /// the designated publisher attempt later atomically writes `active.json` before process exit.
  package static func installPromotedLessonSet(
    _ data: Data,
    expectedDigest: String,
    stateRoot: URL,
    fileManager: FileManager = .default
  ) throws -> URL {
    let sets = stateRoot.appendingPathComponent(
      PageEvaluationContract.lessonSetsDirectoryName,
      isDirectory: true
    )
    try prepareDirectory(stateRoot)
    try prepareDirectory(sets)
    let destination = sets.appendingPathComponent("\(expectedDigest).json", isDirectory: false)
    _ = try verifiedLessonSet(
      data: data,
      path: destination,
      expectedDigest: expectedDigest
    )
    try installImmutable(data, at: destination, fileManager: fileManager)
    return destination
  }
}

private extension EvaluationWorkspaceMaterializer {
  struct ResolvedLessonSet {
    let object: [String: Any]
    let path: URL?
    let digest: String
  }

  static func resetSynthesis(
    configuration: EvaluationAttemptConfiguration,
    workspace: URL,
    source: URL,
    sourceData: Data,
    sourceDigest: String,
    fileManager: FileManager
  ) throws -> EvaluationWorkspaceMaterialization {
    guard
      configuration.condition == .synthesis,
      configuration.lessonSource == .clean,
      configuration.inputSHA256 == sourceDigest,
      let object = try JSONSerialization.jsonObject(with: sourceData) as? [String: Any],
      CanonicalJSON.integer(object["schema_version"]) == 1,
      try canonicalJSONData(object) == sourceData,
      let inputText = String(data: sourceData, encoding: .utf8),
      inputText.count <= PageEvaluationContract.maximumInputGraphemes
    else {
      throw EvaluationWorkspaceError.invalidSynthesisInput
    }
    let emptyLessons: [String: Any] = [
      "lesson_set_id": "empty", "lessons": [], "schema_version": 1,
    ]
    let lessonDigest = SHA256Digest.hex(try canonicalJSONData(emptyLessons))
    guard configuration.lessonSetDigest == lessonDigest else {
      throw EvaluationWorkspaceError.lessonDigestMismatch(
        expected: configuration.lessonSetDigest,
        observed: lessonDigest
      )
    }

    let workspaceWasEmptyAtStart = try resetWorkspace(at: workspace, fileManager: fileManager)
    let destination = workspace.appendingPathComponent(
      PageEvaluationContract.synthesisInputFileName
    )
    try durableReplace(sourceData, at: destination)
    let finalNames = try fileManager.contentsOfDirectory(atPath: workspace.path).sorted()
    guard finalNames == [PageEvaluationContract.synthesisInputFileName] else {
      throw EvaluationWorkspaceError.unexpectedWorkspaceContents(finalNames)
    }
    let receipt = EvaluationCarrierReceipt(
      sourceSHA256: sourceDigest,
      taskID: configuration.taskID,
      lessonSource: .clean,
      lessonSetSHA256: lessonDigest,
      lessonSetID: "empty",
      lessonIDs: [],
      inputSHA256: sourceDigest,
      promotionReceiptSHA256: nil
    )
    return EvaluationWorkspaceMaterialization(
      workspaceWasEmptyAtStart: workspaceWasEmptyAtStart,
      inputWasRegenerated: true,
      inputPath: destination.path,
      inputSHA256: sourceDigest,
      inputByteCount: sourceData.count,
      sourceArtifactPath: source.path,
      sourceSHA256: sourceDigest,
      taskID: configuration.taskID,
      lessonSource: .clean,
      lessonSetPath: nil,
      lessonSetDigest: lessonDigest,
      lessonSetID: "empty",
      lessonIDs: [],
      carrierReceipt: receipt,
      carrierReceiptSHA256: SHA256Digest.hex(try canonicalJSONData(receipt))
    )
  }

  static func resolveLessonSet(
    configuration: EvaluationAttemptConfiguration,
    fileManager: FileManager
  ) throws -> ResolvedLessonSet {
    switch configuration.lessonSource {
    case .clean:
      let object: [String: Any] = [
        "lesson_set_id": "empty",
        "lessons": [],
        "schema_version": 1,
      ]
      let digest = SHA256Digest.hex(try canonicalJSONData(object))
      guard digest == configuration.lessonSetDigest else {
        throw EvaluationWorkspaceError.lessonDigestMismatch(
          expected: configuration.lessonSetDigest,
          observed: digest
        )
      }
      return ResolvedLessonSet(object: object, path: nil, digest: digest)

    case .artifact:
      guard let artifactPath = configuration.lessonArtifactPath else {
        throw EvaluationWorkspaceError.missingLessonArtifact
      }
      let artifact = URL(fileURLWithPath: artifactPath).standardizedFileURL
      let data = try EvaluationPathSecurity.readRegularSingleLinkFile(at: artifact)
      let resolved = try verifiedLessonSet(
        data: data,
        path: artifact,
        expectedDigest: configuration.lessonSetDigest
      )
      if configuration.publishLessonAsActive {
        try publish(resolved, stateRoot: configuration.stateRootURL, fileManager: fileManager)
      }
      return resolved

    case .durableActive:
      let activeURL = configuration.stateRootURL
        .appendingPathComponent(PageEvaluationContract.activeLessonFileName)
      let pointerData: Data
      do {
        try EvaluationPathSecurity.rejectSymlinkComponents(in: [activeURL])
        pointerData = try EvaluationPathSecurity.readRegularSingleLinkFile(at: activeURL)
      } catch {
        throw EvaluationWorkspaceError.invalidActiveLessonPointer
      }
      let pointer: EvaluationActiveLessonPointer
      do {
        pointer = try JSONDecoder().decode(EvaluationActiveLessonPointer.self, from: pointerData)
      } catch {
        throw EvaluationWorkspaceError.invalidActiveLessonPointer
      }
      guard
        pointer.schemaVersion == 1,
        try canonicalJSONData(pointer) == pointerData
      else {
        throw EvaluationWorkspaceError.invalidActiveLessonPointer
      }
      guard pointer.lessonSetSHA256 == configuration.lessonSetDigest else {
        throw EvaluationWorkspaceError.activeLessonDigestMismatch(
          expected: configuration.lessonSetDigest,
          observed: pointer.lessonSetSHA256
        )
      }
      let immutableURL = configuration.stateRootURL
        .appendingPathComponent(PageEvaluationContract.lessonSetsDirectoryName, isDirectory: true)
        .appendingPathComponent("\(pointer.lessonSetSHA256).json")
      let immutableData: Data
      do {
        try EvaluationPathSecurity.rejectSymlinkComponents(in: [immutableURL])
        immutableData = try EvaluationPathSecurity.readRegularSingleLinkFile(at: immutableURL)
      } catch {
        throw EvaluationWorkspaceError.invalidActiveLessonPointer
      }
      let resolved = try verifiedLessonSet(
        data: immutableData,
        path: immutableURL,
        expectedDigest: pointer.lessonSetSHA256
      )
      guard lessonSetID(in: resolved.object) == pointer.lessonSetID else {
        throw EvaluationWorkspaceError.activeLessonIdentityMismatch
      }
      return resolved
    }
  }

  static func verifiedLessonSet(
    data: Data,
    path: URL,
    expectedDigest: String
  ) throws -> ResolvedLessonSet {
    let digest = SHA256Digest.hex(data)
    guard digest == expectedDigest else {
      throw EvaluationWorkspaceError.lessonDigestMismatch(
        expected: expectedDigest,
        observed: digest
      )
    }
    let object = try object(from: data, source: false)
    guard try validatedLessonIdentity(in: object), try canonicalJSONData(object) == data else {
      throw EvaluationWorkspaceError.invalidLessonArtifact
    }
    return ResolvedLessonSet(object: object, path: path, digest: digest)
  }

  static func publish(
    _ lesson: ResolvedLessonSet,
    stateRoot: URL,
    fileManager: FileManager
  ) throws {
    let sets = stateRoot.appendingPathComponent(
      PageEvaluationContract.lessonSetsDirectoryName,
      isDirectory: true
    )
    try prepareDirectory(stateRoot)
    try prepareDirectory(sets)
    let immutable = sets.appendingPathComponent("\(lesson.digest).json")
    let bytes = try canonicalJSONData(lesson.object)
    try installImmutable(bytes, at: immutable, fileManager: fileManager)

    guard let identifier = lessonSetID(in: lesson.object) else {
      throw EvaluationWorkspaceError.invalidLessonArtifact
    }
    let pointer = EvaluationActiveLessonPointer(
      lessonSetID: identifier,
      lessonSetSHA256: lesson.digest
    )
    let pointerData = try canonicalJSONData(pointer)
    let active = stateRoot.appendingPathComponent(PageEvaluationContract.activeLessonFileName)
    try durableReplace(pointerData, at: active)
  }

  static func lessonSetID(in object: [String: Any]) -> String? {
    object["lesson_set_id"] as? String
  }

  static func lessonIDs(in object: [String: Any]) -> [String] {
    guard let lessons = object["lessons"] as? [[String: Any]] else { return [] }
    return lessons.compactMap { $0["lesson_id"] as? String }
  }

  static func validatedLessonIdentity(in object: [String: Any]) throws -> Bool {
    guard
      Set(object.keys) == Set(["schema_version", "lesson_set_id", "lessons"]),
      CanonicalJSON.integer(object["schema_version"]) == 1,
      let setID = lessonSetID(in: object),
      validToken(setID),
      let lessons = object["lessons"] as? [[String: Any]],
      lessons.count <= 3
    else {
      return false
    }
    let allowedClasses = Set([
      "noise.volatile_value",
      "noise.time_or_build_metadata",
      "noise.structure_or_order",
    ])
    var ids = Set<String>()
    var classes = Set<String>()
    var textScalars = 0
    for lesson in lessons {
      guard
        Set(lesson.keys) == Set(["lesson_id", "target_class", "text"]),
        let identifier = lesson["lesson_id"] as? String,
        validToken(identifier),
        ids.insert(identifier).inserted,
        let targetClass = lesson["target_class"] as? String,
        allowedClasses.contains(targetClass),
        classes.insert(targetClass).inserted,
        let text = lesson["text"] as? String,
        (1...400).contains(text.unicodeScalars.count)
      else {
        return false
      }
      textScalars += text.unicodeScalars.count
    }
    return textScalars <= 1_000
  }

  static func validToken(_ value: String) -> Bool {
    guard (1...64).contains(value.unicodeScalars.count) else { return false }
    return value.unicodeScalars.allSatisfy { scalar in
      (0x61...0x7A).contains(scalar.value)
        || (0x30...0x39).contains(scalar.value)
        || scalar.value == 0x2D
    }
  }

  static func object(from data: Data, source: Bool) throws -> [String: Any] {
    guard
      let object = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    else {
      throw source
        ? EvaluationWorkspaceError.invalidSourceArtifact
        : EvaluationWorkspaceError.invalidLessonArtifact
    }
    return object
  }

  static func canonicalJSONData(_ value: Any) throws -> Data {
    try EvaluationCanonicalJSON.data(fromJSONObject: value)
  }

  static func canonicalJSONData<Value: Encodable>(_ value: Value) throws -> Data {
    try EvaluationCanonicalJSON.data(encoding: value)
  }

  static func prepareDirectory(_ directory: URL) throws {
    try EvaluationPathSecurity.ensurePrivateDirectory(at: directory)
  }

  static func installImmutable(_ data: Data, at destination: URL, fileManager: FileManager) throws {
    try EvaluationPathSecurity.rejectSymlinkComponents(in: [destination])
    if fileManager.fileExists(atPath: destination.path) {
      guard
        try EvaluationPathSecurity.readRegularSingleLinkFile(
          at: destination,
          expectedByteCount: data.count
        ) == data
      else {
        throw EvaluationWorkspaceError.immutableLessonCollision(destination.path)
      }
    } else {
      try durableReplace(data, at: destination)
    }
  }

  static func resetWorkspace(at workspace: URL, fileManager: FileManager) throws -> Bool {
    try EvaluationPathSecurity.rejectSymlinkComponents(in: [workspace])
    var isDirectory: ObjCBool = false
    let existed = fileManager.fileExists(atPath: workspace.path, isDirectory: &isDirectory)
    let wasEmpty =
      if existed, isDirectory.boolValue {
        try fileManager.contentsOfDirectory(atPath: workspace.path).isEmpty
      } else {
        false
      }
    try prepareDirectory(workspace)
    for child in try fileManager.contentsOfDirectory(
      at: workspace,
      includingPropertiesForKeys: nil,
      options: []
    ) {
      try fileManager.removeItem(at: child)
    }
    let remaining = try fileManager.contentsOfDirectory(atPath: workspace.path).sorted()
    guard remaining.isEmpty else {
      throw EvaluationWorkspaceError.unexpectedWorkspaceContents(remaining)
    }
    return wasEmpty
  }

  static func durableReplace(_ data: Data, at destination: URL) throws {
    try EvaluationDurablePublication.publish(data, to: destination)
  }

}

enum EvaluationWorkspaceError: Error, Sendable, Equatable {
  case sourceArtifactInsideWorkspace
  case lessonArtifactInsideWorkspace
  case sourceDigestMismatch(expected: String, observed: String)
  case invalidSourceArtifact
  case invalidSynthesisInput
  case missingLessonArtifact
  case lessonDigestMismatch(expected: String, observed: String)
  case invalidLessonArtifact
  case invalidActiveLessonPointer
  case activeLessonDigestMismatch(expected: String, observed: String)
  case activeLessonIdentityMismatch
  case immutableLessonCollision(String)
  case inputDigestMismatch(expected: String, observed: String)
  case inputIsNotUTF8
  case inputGraphemeLimitExceeded(Int)
  case unexpectedWorkspaceContents([String])
}

package enum EvaluationJSONFile {
  package static func decode<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value {
    let decoder = JSONDecoder()
    return try decoder.decode(
      type,
      from: EvaluationPathSecurity.readRegularSingleLinkFile(at: url)
    )
  }

  package static func write<Value: Encodable>(_ value: Value, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    try EvaluationPathSecurity.ensurePrivateDirectory(at: url.deletingLastPathComponent())
    try EvaluationDurablePublication.publish(data, to: url)
  }
}
