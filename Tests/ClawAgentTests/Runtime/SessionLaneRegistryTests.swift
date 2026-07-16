import ClawTestSupport
import Foundation
import Testing

@testable import ClawAgent

/// The turn-lifecycle owner: atomic admission, per-session FIFO across suspension, cross-session
/// concurrency, operation-ID-guarded finalization (a stale completion must never clear a newer
/// tail), and a bounded drain that waits for every registered turn's full work closure to return.
///
/// The one-minute limits are deadlock guards, not timing assertions: every wait is released through
/// an `AsyncGate` or a `ScriptedClock`, never a sleep.
@Suite struct SessionLaneRegistryTests {
  /// Records ordered string events and lets a test await a given count without polling.
  private actor Recorder {
    private var events: [String] = []
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func record(_ event: String) {
      events.append(event)
      var stillWaiting: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
      for waiter in waiters {
        if events.count >= waiter.count {
          waiter.continuation.resume()
        } else {
          stillWaiting.append(waiter)
        }
      }
      waiters = stillWaiting
    }

    func snapshot() -> [String] {
      events
    }

    func waitForCount(_ count: Int) async {
      if events.count >= count {
        return
      }
      await withCheckedContinuation { continuation in
        waiters.append((count: count, continuation: continuation))
      }
    }
  }

  /// Hands the cooperative scheduler enough turns for any already-runnable lane task to make its
  /// progress. Never blocks a thread, so it is safe at nproc=1; used only to give a *bug's*
  /// out-of-order turn a fair chance to misbehave before a negative assertion.
  private func yieldRepeatedly() async {
    for _ in 0..<50 {
      await Task.yield()
    }
  }

  /// A clock whose `sleep` fires immediately, so the timeout always wins a drain race.
  private func immediateClock() -> ScriptedClock {
    ScriptedClock { _ in }
  }

  /// A clock whose `sleep` parks on `hold` — the deadline never fires until a test opens the gate,
  /// and it returns on cancellation so a drain that already drained can consume it.
  private func heldClock(_ hold: AsyncGate) -> ScriptedClock {
    ScriptedClock { _ in
      await hold.wait()
    }
  }

  // MARK: - FIFO & Concurrency

  @Test(.timeLimit(.minutes(1)))
  func completeTurnsRunFifoAcrossSuspension() async {
    // given
    let registry = SessionLaneRegistry()
    let recorder = Recorder()
    let firstBody = AsyncGate()

    // when — the first turn suspends mid-body; the second must not interleave.
    _ = await registry.enqueue(sessionID: 1, runID: 1) {
      await recorder.record("a-start")
      await firstBody.wait()
      await recorder.record("a-end")
    }
    _ = await registry.enqueue(sessionID: 1, runID: 2) {
      await recorder.record("b-start")
      await recorder.record("b-end")
    }
    firstBody.open()
    await recorder.waitForCount(4)

    // then
    #expect(await recorder.snapshot() == ["a-start", "a-end", "b-start", "b-end"])
  }

  @Test(.timeLimit(.minutes(1)))
  func differentSessionsRunConcurrently() async {
    // given
    let registry = SessionLaneRegistry()
    let recorder = Recorder()
    let release = AsyncGate()

    // when — session 1's turn blocks; session 2 must still make progress.
    _ = await registry.enqueue(sessionID: 1, runID: 1) {
      await release.wait()
      await recorder.record("one")
    }
    _ = await registry.enqueue(sessionID: 2, runID: 2) {
      await recorder.record("two")
    }
    await recorder.waitForCount(1)

    // then — "two" landed while "one" is still blocked, proving no cross-session serialization.
    #expect(await recorder.snapshot() == ["two"])
    release.open()
    await recorder.waitForCount(2)
    #expect(Set(await recorder.snapshot()) == ["one", "two"])
  }

  // MARK: - Atomic Admission

  @Test(.timeLimit(.minutes(1)))
  func postCloseEnqueueIsNeverAcceptedAndWorkNeverStarts() async {
    // given
    let registry = SessionLaneRegistry()
    let recorder = Recorder()

    // when — admission closes before the enqueue.
    registry.closeAdmission()
    let result = await registry.enqueue(sessionID: 1, runID: 1) {
      await recorder.record("ran")
    }

    // then — rejected, and the rejected work never started.
    #expect(result == .shuttingDown)
    #expect(await registry.activeRunIDs() == [])
    #expect(await recorder.snapshot() == [])
  }

  @Test(.timeLimit(.minutes(1)))
  func preCloseEnqueueRunsToCompletion() async {
    // given — the positive twin of the negative above, so a guard that always rejects cannot pass.
    let registry = SessionLaneRegistry()
    let recorder = Recorder()

    // when
    let result = await registry.enqueue(sessionID: 1, runID: 1) {
      await recorder.record("ran")
    }
    await recorder.waitForCount(1)

    // then
    #expect(result == .accepted)
    #expect(await recorder.snapshot() == ["ran"])
  }

  @Test(.timeLimit(.minutes(1)))
  func stopAcceptingRejectsLaterEnqueuesAndCancelsRunning() async {
    // given
    let registry = SessionLaneRegistry()
    let running = AsyncGate()
    let observed = AsyncGate()
    let cancellation = Cancellation()

    _ = await registry.enqueue(sessionID: 1, runID: 1) {
      running.open()
      await observed.wait()
      await cancellation.record(Task.isCancelled)
    }
    await running.wait()

    // when
    await registry.stopAcceptingAndCancel()
    let rejected = await registry.enqueue(sessionID: 1, runID: 2) {
      await cancellation.record(false)
    }
    observed.open()
    await cancellation.waitForCount(1)

    // then — the later enqueue is rejected and the running turn observed cancellation.
    #expect(rejected == .shuttingDown)
    #expect(await cancellation.values == [true])
  }

  @Test(.timeLimit(.minutes(1)))
  func everyAcceptedRunIsPresentInActiveRunIDs() async {
    // given
    let registry = SessionLaneRegistry()
    let hold = AsyncGate()

    // when — three accepted, gated turns across two sessions.
    _ = await registry.enqueue(sessionID: 1, runID: 10) { await hold.wait() }
    _ = await registry.enqueue(sessionID: 1, runID: 11) { await hold.wait() }
    _ = await registry.enqueue(sessionID: 2, runID: 12) { await hold.wait() }

    // then — registration is synchronous with enqueue: a run cannot finish before it is registered.
    #expect(await registry.activeRunIDs() == [10, 11, 12])
    hold.open()
  }

  // MARK: - Cancellation

  @Test(.timeLimit(.minutes(1)))
  func cancelQueuedRunStillReachesItsBodyToSelfAbort() async {
    // given — the queued turn must still run its body (observing cancellation) so it can self-abort
    // its durable row rather than being silently dropped.
    let registry = SessionLaneRegistry()
    let recorder = Recorder()
    let firstBody = AsyncGate()

    _ = await registry.enqueue(sessionID: 1, runID: 1) {
      await firstBody.wait()
      await recorder.record("a")
    }
    _ = await registry.enqueue(sessionID: 1, runID: 2) {
      await recorder.record(Task.isCancelled ? "b-cancelled" : "b-running")
    }

    // when — cancel the queued run before its predecessor releases.
    await registry.cancel(runID: 2)
    firstBody.open()
    await recorder.waitForCount(2)

    // then
    #expect(await recorder.snapshot() == ["a", "b-cancelled"])
  }

  @Test(.timeLimit(.minutes(1)))
  func cancelRunningRunIsObservedByItsBody() async {
    // given
    let registry = SessionLaneRegistry()
    let running = AsyncGate()
    let observe = AsyncGate()
    let cancellation = Cancellation()

    _ = await registry.enqueue(sessionID: 1, runID: 7) {
      running.open()
      await observe.wait()
      await cancellation.record(Task.isCancelled)
    }
    await running.wait()

    // when
    await registry.cancel(runID: 7)
    observe.open()
    await cancellation.waitForCount(1)

    // then
    #expect(await cancellation.values == [true])
  }

  @Test(.timeLimit(.minutes(1)))
  func cancelAllStopsEverySessionTurn() async {
    // given
    let registry = SessionLaneRegistry()
    let firstRunning = AsyncGate()
    let observe = AsyncGate()
    let cancellation = Cancellation()

    _ = await registry.enqueue(sessionID: 1, runID: 1) {
      firstRunning.open()
      await observe.wait()
      await cancellation.record(Task.isCancelled)
    }
    _ = await registry.enqueue(sessionID: 1, runID: 2) {
      await cancellation.record(Task.isCancelled)
    }
    await firstRunning.wait()

    // when
    await registry.cancelAll(sessionID: 1)
    observe.open()
    await cancellation.waitForCount(2)

    // then — both the running and the queued-behind turn observed cancellation.
    #expect(await cancellation.values == [true, true])
  }

  @Test(.timeLimit(.minutes(1)))
  func turnCancelledWhileAwaitingPredecessorStillUnregisters() async {
    // given
    let registry = SessionLaneRegistry()
    let firstBody = AsyncGate()

    _ = await registry.enqueue(sessionID: 1, runID: 1) {
      await firstBody.wait()
    }
    _ = await registry.enqueue(sessionID: 1, runID: 2) {
      // never signalled; only reached after the predecessor releases.
    }

    // when — cancel the queued run while it is parked on its predecessor, then release the head.
    await registry.cancel(runID: 2)
    firstBody.open()

    // then — a drain whose deadline never fires returns .drained only because the
    // cancelled-while-waiting turn still unregistered through its finalizer.
    let clockHold = AsyncGate()
    let result = await registry.drain(timeout: .seconds(30), clock: heldClock(clockHold))
    #expect(result == .drained)
    #expect(await registry.activeRunIDs() == [])
    clockHold.open()
  }

  // MARK: - Operation-ID Finalizer

  @Test(.timeLimit(.minutes(1)))
  func staleCompletionDoesNotClearANewerTail() async {
    // given — three turns on ONE session. The finalizer must compare the operation ID, never a Task
    // handle or the map's emptiness: when the head completes it must NOT clear the tail a later
    // enqueue installed, or the third turn would lose its predecessor and jump the queue.
    let registry = SessionLaneRegistry()
    let recorder = Recorder()
    let headBody = AsyncGate()
    let secondBody = AsyncGate()

    _ = await registry.enqueue(sessionID: 1, runID: 1) {
      await headBody.wait()
      await recorder.record("1")
    }
    _ = await registry.enqueue(sessionID: 1, runID: 2) {
      await secondBody.wait()
      await recorder.record("2")
    }

    // when — let the head finish and finalize while the second turn (the tail) is still queued. The
    // yields ensure the head's finalizer has actually run before the third turn is enqueued, so a
    // stale-clear bug has already wiped the tail by then.
    headBody.open()
    await recorder.waitForCount(1)
    await yieldRepeatedly()

    // Enqueue a third turn AFTER the head finalized. It must chain behind the still-pending second
    // turn (the tail), not run immediately. The yields then give a bug's unchained third turn every
    // chance to run — cooperative yields only, never a sleep.
    _ = await registry.enqueue(sessionID: 1, runID: 3) {
      await recorder.record("3")
    }
    await yieldRepeatedly()

    // then — the third turn is still queued behind the second (only "1" recorded). Under a
    // stale-clear bug the head's finalize wiped the tail, the third turn had no predecessor, and it
    // has recorded "3" out of order by now.
    #expect(await recorder.snapshot() == ["1"])

    // and — releasing the second turn lets both drain in order.
    secondBody.open()
    await recorder.waitForCount(3)
    #expect(await recorder.snapshot() == ["1", "2", "3"])
  }

  // MARK: - Drain

  @Test(.timeLimit(.minutes(1)))
  func drainOnAnIdleRegistryIsDrainedAndIdempotent() async {
    // given
    let registry = SessionLaneRegistry()

    // when / then — no in-flight work: drained, and a repeat call is equally drained.
    #expect(await registry.drain(timeout: .seconds(1), clock: immediateClock()) == .drained)
    #expect(await registry.drain(timeout: .seconds(1), clock: immediateClock()) == .drained)
  }

  @Test(.timeLimit(.minutes(1)))
  func drainWaitsForTheFullWorkClosureToReturn() async {
    // given — the work closure records its end as its LAST line; the drain records right after it
    // returns. If drain returns before the closure did, the two records flip order. (Task-25
    // pattern: distinctive ordered values through gates, never a sleep.)
    let registry = SessionLaneRegistry()
    let recorder = Recorder()
    let midFlight = AsyncGate()
    let hold = AsyncGate()
    let drainEntered = AsyncGate()
    let clockHold = AsyncGate()

    _ = await registry.enqueue(sessionID: 1, runID: 1) {
      midFlight.open()
      await hold.wait()
      await recorder.record("closure-end")
    }
    await midFlight.wait()

    // The clock signals when drain has entered (created its deadline child), so the release below
    // races nothing: a correct drain is by then parked on its waiter, a bug's drain has already
    // returned.
    let drainClock = ScriptedClock { _ in
      drainEntered.open()
      await clockHold.wait()
    }
    let drainTask = Task {
      let result = await registry.drain(timeout: .seconds(30), clock: drainClock)
      await recorder.record("drain-returned")
      return result
    }
    await drainEntered.wait()

    // when — give a bug's already-returned drain every chance to record first, THEN release the
    // closure. A correct drain is still parked, so its record can only land after "closure-end".
    await yieldRepeatedly()
    hold.open()

    // then — drain returned .drained, strictly AFTER the closure's final line.
    let result = await drainTask.value
    #expect(result == .drained)
    #expect(await recorder.snapshot() == ["closure-end", "drain-returned"])
    clockHold.open()
  }

  @Test(.timeLimit(.minutes(1)))
  func drainTimesOutAndReportsStillActiveRuns() async {
    // given — a turn wedged past the deadline.
    let registry = SessionLaneRegistry()
    let hold = AsyncGate()
    _ = await registry.enqueue(sessionID: 1, runID: 42) {
      await hold.wait()
    }

    // when — the immediate clock makes the deadline win the race.
    let result = await registry.drain(timeout: .seconds(1), clock: immediateClock())

    // then — the still-active run is reported.
    #expect(result == .timedOut(activeRunIDs: [42]))

    // cleanup — release the wedged turn so nothing is stranded.
    hold.open()
    _ = await registry.drain(timeout: .seconds(30), clock: heldClock(AsyncGate()))
  }

  @Test(.timeLimit(.minutes(1)))
  func drainAfterStopDrainsCancelledTurns() async {
    // given — a running turn that will observe cancellation and then return.
    let registry = SessionLaneRegistry()
    let running = AsyncGate()
    let clockHold = AsyncGate()
    _ = await registry.enqueue(sessionID: 1, runID: 5) {
      running.open()
      // Return promptly once cancelled, mimicking a turn self-aborting its durable row.
      while !Task.isCancelled {
        await Task.yield()
      }
    }
    await running.wait()

    // when — stop (cancels the running turn) then drain.
    await registry.stopAcceptingAndCancel()
    let result = await registry.drain(timeout: .seconds(30), clock: heldClock(clockHold))

    // then — the cancelled turn drained to completion.
    #expect(result == .drained)
    #expect(await registry.activeRunIDs() == [])
    clockHold.open()
  }
}

// MARK: - Cancellation Recorder

/// Records the `Task.isCancelled` a turn body observed, in order.
private actor Cancellation {
  private var seen: [Bool] = []
  private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

  var values: [Bool] {
    seen
  }

  func record(_ wasCancelled: Bool) {
    seen.append(wasCancelled)
    var stillWaiting: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    for waiter in waiters {
      if seen.count >= waiter.count {
        waiter.continuation.resume()
      } else {
        stillWaiting.append(waiter)
      }
    }
    waiters = stillWaiting
  }

  func waitForCount(_ count: Int) async {
    if seen.count >= count {
      return
    }
    await withCheckedContinuation { continuation in
      waiters.append((count: count, continuation: continuation))
    }
  }
}
