import ClawTestSupport
import Testing

enum CoderToolCleanupError: Error { case lanesNotDrained }

actor CoderToolStorageCleanup {
  private(set) var deletionAllowed = true

  func retainFiles() {
    deletionAllowed = false
  }
}

extension CoderServiceFixture {
  func withJoinedCleanup(_ operation: () async throws -> Void) async throws {
    try await withCoderToolCleanup(operation: operation) {
      backend.releaseAll()
      try await service.shutdown()
      cleanup()
    }
  }
}

extension SC3Harness {
  func withJoinedCleanup(
    backend: ScriptedCoderBackend,
    storage: CoderToolStorageCleanup = CoderToolStorageCleanup(),
    removeFilesOnExit: Bool = true,
    _ operation: () async throws -> Void
  ) async throws {
    try await withCoderToolCleanup(operation: operation) {
      backend.releaseAll()
      do {
        try await stop()
      } catch {
        await storage.retainFiles()
        throw error
      }
      if removeFilesOnExit, await storage.deletionAllowed { removeFiles() }
    }
  }
}

private func withCoderToolCleanup(
  operation: () async throws -> Void,
  cleanup: () async throws -> Void
) async throws {
  do {
    try await operation()
  } catch {
    let operationError = error
    do { try await cleanup() } catch { Issue.record(error) }
    throw operationError
  }
  try await cleanup()
}
