import ClawCore
import Foundation

/// The one fetcher double for the `MediaFetching` seam: returns canned bytes or throws, and
/// records every call's fileId AND maxBytes so tests can assert both what was fetched and that
/// the bounded-download cap survives the middle of the chain.
struct StubMediaFetcher: MediaFetching {
  struct Call: Sendable, Equatable {
    let fileId: String
    let maxBytes: Int
  }

  actor Recorder {
    private(set) var calls: [Call] = []

    func append(_ call: Call) {
      calls.append(call)
    }
  }

  /// The unremarkable download failure, for tests that care only that no bytes came back.
  struct FetchFailed: Error {}

  private static let oggHeader = Data([0x4F, 0x67, 0x67, 0x53])  // "OggS"

  let recorder = Recorder()
  let result: Result<Data, any Error & Sendable>

  var calls: [Call] {
    get async {
      await recorder.calls
    }
  }

  init(result: Result<Data, any Error & Sendable>) {
    self.result = result
  }

  /// Audio-shaped convenience: canned bytes, or `nil` for a plain download failure.
  init(audio: Data? = StubMediaFetcher.oggHeader) {
    guard let audio else {
      self.init(result: .failure(FetchFailed()))
      return
    }
    self.init(result: .success(audio))
  }

  func downloadFile(fileId: String, maxBytes: Int) async throws -> Data {
    await recorder.append(Call(fileId: fileId, maxBytes: maxBytes))
    return try result.get()
  }
}

/// Parks until the surrounding task is cancelled — a cancellable wait, not a timing sleep — and then
/// reports a plain download failure, the shape a transport that spells cancellation in its own error
/// type produces.
struct ParkUntilCancelledFetcher: MediaFetching {
  func downloadFile(fileId: String, maxBytes: Int) async throws -> Data {
    try? await Task.sleep(for: .seconds(3_600))
    throw StubMediaFetcher.FetchFailed()
  }
}
