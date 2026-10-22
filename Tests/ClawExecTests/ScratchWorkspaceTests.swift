import ClawCore
import Foundation
import Testing

@testable import ClawExec

@Suite
struct ScratchWorkspaceTests {
  /// One violation per case: `validate` throws at its first failing guard, so a request that
  /// stacked several would let any one guard be deleted while the next still threw.
  enum InvalidRequestCase: CaseIterable {
    case pathEscapingInput
    case reservedEntrypointNameAsInput
    case caseFoldedDuplicateInputs
    case executableInput
    case entrypointNamedForAnotherLanguage
    case readOnlyEntrypoint

    var request: ExecutionRequest {
      switch self {
      case .pathEscapingInput:
        requestWith(inputs: [Self.input("../escape")])
      case .reservedEntrypointNameAsInput:
        requestWith(inputs: [Self.input(".clawd-entrypoint.payload")])
      case .caseFoldedDuplicateInputs:
        requestWith(inputs: [Self.input("Readme"), Self.input("README")])
      case .executableInput:
        requestWith(inputs: [StagedFile(name: "input", bytes: Data(), mode: .readExecute)])
      case .entrypointNamedForAnotherLanguage:
        requestWith(language: .sh)
      case .readOnlyEntrypoint:
        requestWith(
          entrypoint: StagedFile(
            name: ".clawd-entrypoint.py",
            bytes: Data("print('ok')".utf8),
            mode: .readOnly
          )
        )
      }
    }

    var reason: String {
      switch self {
      case .pathEscapingInput, .reservedEntrypointNameAsInput:
        "invalid staged input name"
      case .caseFoldedDuplicateInputs:
        "duplicate staged input name"
      case .executableInput:
        "staged input mode is not read-only"
      case .entrypointNamedForAnotherLanguage, .readOnlyEntrypoint:
        "invalid execution entrypoint"
      }
    }
  }

  @Test
  func materializerCreatesPrivateRootsExactFilesAndExternalCidfile() throws {
    // given
    let fixture = try ScratchFixture()
    defer { fixture.remove() }
    let identity = try fixedIdentity()
    let request = executionRequest(
      input: StagedFile(name: "input.txt", bytes: Data("private copy".utf8), mode: .readOnly)
    )

    // when
    let workspace = try ScratchWorkspace.create(
      stateRoot: fixture.root,
      identity: identity,
      request: request
    )

    // then
    #expect(try permissions(workspace.scratchRoot) == 0o700)
    #expect(try permissions(workspace.controlRoot) == 0o700)
    #expect(try permissions(workspace.directory) == 0o700)
    #expect(try permissions(workspace.directory.appending(path: ".clawd-entrypoint.py")) == 0o500)
    #expect(try permissions(workspace.directory.appending(path: "input.txt")) == 0o400)
    #expect(
      try Data(contentsOf: workspace.directory.appending(path: "input.txt"))
        == Data("private copy".utf8)
    )
    #expect(workspace.cidFile.deletingLastPathComponent() == workspace.controlRoot)
    #expect(!workspace.cidFile.path.hasPrefix(workspace.directory.path + "/"))
  }

  @Test(arguments: InvalidRequestCase.allCases)
  func materializerRejectsEachInvalidRequestBeforeRunDirectory(
    _ invalidCase: InvalidRequestCase
  ) throws {
    // given
    let fixture = try ScratchFixture()
    defer { fixture.remove() }

    // when / then
    #expect(throws: ScratchWorkspaceError.invalidRequest(invalidCase.reason)) {
      try ScratchWorkspace.create(
        stateRoot: fixture.root,
        identity: try fixedIdentity(),
        request: invalidCase.request
      )
    }
    let runDirectory = fixture.root.appending(path: "exec-scratch").appending(
      path: try fixedIdentity().identifier
    )
    #expect(!FileManager.default.fileExists(atPath: runDirectory.path))
  }

  @Test
  func materializerRefusesStateRootThatCannotCrossAMountDirective() throws {
    // given
    let root = FileManager.default.temporaryDirectory.appending(
      path: "clawd-scratch-tests-comma,\(UUID().uuidString.lowercased())"
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }

    // when / then
    #expect(
      throws: ScratchWorkspaceError.invalidRequest(
        "state root path contains characters that cannot cross a mount directive"
      )
    ) {
      try ScratchWorkspace.create(
        stateRoot: root,
        identity: try fixedIdentity(),
        request: executionRequest()
      )
    }
    let scratchRoot = root.appending(path: "exec-scratch")
    #expect(!FileManager.default.fileExists(atPath: scratchRoot.path))
  }

  @Test
  func materializerEnforcesEntrypointPerFileAndTotalBounds() throws {
    // given
    let fixture = try ScratchFixture()
    defer { fixture.remove() }
    let oversizedEntrypoint = StagedFile(
      name: ".clawd-entrypoint.py",
      bytes: Data(repeating: 0x61, count: ScratchWorkspace.maxEntrypointBytes + 1),
      mode: .readExecute
    )
    let oversizedInput = StagedFile(
      name: "large",
      bytes: Data(repeating: 0x62, count: ScratchWorkspace.maxInputBytes + 1),
      mode: .readOnly
    )

    // when / then
    #expect(throws: ScratchWorkspaceError.self) {
      try ScratchWorkspace.create(
        stateRoot: fixture.root,
        identity: try fixedIdentity(),
        request: ExecutionRequest(
          language: .python,
          entrypoint: oversizedEntrypoint,
          inputs: [],
          network: false,
          timeout: .seconds(1)
        )
      )
    }
    #expect(throws: ScratchWorkspaceError.self) {
      try ScratchWorkspace.create(
        stateRoot: fixture.root,
        identity: try fixedIdentity(),
        request: ExecutionRequest(
          language: .python,
          entrypoint: pythonEntrypoint(),
          inputs: [oversizedInput],
          network: false,
          timeout: .seconds(1)
        )
      )
    }
  }

  @Test
  func workspaceRemovalDeletesScratchAndCidfileIdempotently() throws {
    // given
    let fixture = try ScratchFixture()
    defer { fixture.remove() }
    let workspace = try ScratchWorkspace.create(
      stateRoot: fixture.root,
      identity: try fixedIdentity(),
      request: executionRequest()
    )
    FileManager.default.createFile(atPath: workspace.cidFile.path, contents: Data("owned".utf8))

    // when
    try workspace.remove()
    try workspace.remove()

    // then
    #expect(!FileManager.default.fileExists(atPath: workspace.directory.path))
    #expect(!FileManager.default.fileExists(atPath: workspace.cidFile.path))
  }
}

// MARK: - Invalid Request Builders

private extension ScratchWorkspaceTests.InvalidRequestCase {
  static func input(_ name: String) -> StagedFile {
    StagedFile(name: name, bytes: Data(), mode: .readOnly)
  }

  func requestWith(
    language: ExecLanguage = .python,
    entrypoint: StagedFile = pythonEntrypoint(),
    inputs: [StagedFile] = []
  ) -> ExecutionRequest {
    ExecutionRequest(
      language: language,
      entrypoint: entrypoint,
      inputs: inputs,
      network: false,
      timeout: .seconds(1)
    )
  }
}
