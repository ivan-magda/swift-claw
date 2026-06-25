import Foundation
import Testing

@testable import ClawAgent

@Suite struct SessionActorTests {
  actor Recorder {
    private var events: [String] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func append(_ event: String) {
      events.append(event)
      for continuation in continuations {
        continuation.resume()
      }
      continuations.removeAll()
    }

    func snapshot() -> [String] {
      events
    }

    func waitForCount(_ count: Int) async {
      while events.count < count {
        await withCheckedContinuation { continuation in
          continuations.append(continuation)
        }
      }
    }
  }

  @Test func queuedWorkRunsFifoAndDoesNotInterleave() async {
    // given
    let lane = SessionActor()
    let recorder = Recorder()

    // when
    await lane.enqueue(runId: 1) {
      await recorder.append("a-start")
      try? await Task.sleep(for: .milliseconds(20))
      await recorder.append("a-end")
    }
    await lane.enqueue(runId: 2) {
      await recorder.append("b-start")
      await recorder.append("b-end")
    }
    await recorder.waitForCount(4)

    // then
    #expect(await recorder.snapshot() == ["a-start", "a-end", "b-start", "b-end"])
  }

  @Test func cancelledQueuedTaskStillReachesWorkBodyForDatabaseSelfAbort() async {
    // given
    let lane = SessionActor()
    let recorder = Recorder()

    // when
    await lane.enqueue(runId: 1) {
      try? await Task.sleep(for: .milliseconds(20))
      await recorder.append("a")
    }
    await lane.enqueue(runId: 2) {
      await recorder.append(Task.isCancelled ? "b-cancelled" : "b-running")
    }
    await lane.cancel(runId: 2)
    await recorder.waitForCount(2)

    // then
    #expect(await recorder.snapshot() == ["a", "b-cancelled"])
  }

  @Test func registryReusesActorsPerSession() async {
    // given
    let registry = SessionLaneRegistry()

    // when
    let first = await registry.actor(for: 1)
    let again = await registry.actor(for: 1)
    let second = await registry.actor(for: 2)

    // then
    #expect(first === again)
    #expect(first !== second)
    #expect(await registry.count == 2)
  }
}
