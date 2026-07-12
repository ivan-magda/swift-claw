import ClawCore
import Foundation
import Testing

@testable import ClawExec

@Suite struct ContainerBackendTests {
  @Test func materializerCreatesPrivateRootsExactFilesAndExternalCidfile() throws {
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

  @Test func materializerRejectsPathReservedAndCaseFoldedCollisionsBeforeRunDirectory() throws {
    // given
    let fixture = try ScratchFixture()
    defer { fixture.remove() }
    let badInputs = [
      StagedFile(name: "../escape", bytes: Data(), mode: .readOnly),
      StagedFile(name: ".clawd-entrypoint.payload", bytes: Data(), mode: .readOnly),
      StagedFile(name: "Readme", bytes: Data(), mode: .readOnly),
      StagedFile(name: "README", bytes: Data(), mode: .readOnly),
    ]
    let request = ExecutionRequest(
      language: .python,
      entrypoint: pythonEntrypoint(),
      inputs: badInputs,
      network: false,
      timeout: .seconds(1)
    )

    // when
    let result = Result {
      try ScratchWorkspace.create(
        stateRoot: fixture.root,
        identity: try fixedIdentity(),
        request: request
      )
    }

    // then
    #expect(throws: ScratchWorkspaceError.self) { try result.get() }
    let runDirectory = fixture.root.appending(path: "exec-scratch")
      .appending(path: try fixedIdentity().identifier)
    #expect(!FileManager.default.fileExists(atPath: runDirectory.path))
  }

  @Test func materializerRejectsWrongEntrypointNameAndModes() throws {
    // given
    let fixture = try ScratchFixture()
    defer { fixture.remove() }
    let request = ExecutionRequest(
      language: .sh,
      entrypoint: StagedFile(
        name: ".clawd-entrypoint.py",
        bytes: Data("echo no".utf8),
        mode: .readOnly
      ),
      inputs: [StagedFile(name: "input", bytes: Data(), mode: .readExecute)],
      network: false,
      timeout: .seconds(1)
    )

    // when / then
    #expect(throws: ScratchWorkspaceError.self) {
      try ScratchWorkspace.create(
        stateRoot: fixture.root,
        identity: try fixedIdentity(),
        request: request
      )
    }
  }

  @Test func materializerEnforcesEntrypointPerFileAndTotalBounds() throws {
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

  @Test func workspaceRemovalDeletesScratchAndCidfileIdempotently() throws {
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

private struct ScratchFixture {
  let root: URL

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appending(path: "clawd-scratch-tests-\(UUID().uuidString.lowercased())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

private func fixedIdentity() throws -> ExecutionIdentity {
  ExecutionIdentity(uuid: try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555")))
}

private func pythonEntrypoint() -> StagedFile {
  StagedFile(name: ".clawd-entrypoint.py", bytes: Data("print('ok')".utf8), mode: .readExecute)
}

private func executionRequest(input: StagedFile? = nil) -> ExecutionRequest {
  ExecutionRequest(
    language: .python,
    entrypoint: pythonEntrypoint(),
    inputs: input.map { staged in
      [staged]
    } ?? [],
    network: false,
    timeout: .seconds(1)
  )
}

private func permissions(_ url: URL) throws -> Int {
  let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
  return try #require((attributes[.posixPermissions] as? NSNumber)?.intValue)
}
