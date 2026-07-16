import ClawAgent
import ClawTestSupport
import ServiceLifecycle
import ServiceLifecycleTestKit
import Synchronization
import Testing

@testable import ClawGateway

@Suite struct LaneAdmissionShutdownServiceTests {
  /// A scripted clock whose drain-deadline sleep signals `drainStarted` (proving the full shutdown
  /// sequence — close admission, cancel, begin drain — has run) and then parks on `holdDeadline`.
  /// The park is cancellation-aware, so a clean drain's `deadline.cancel()` releases it; opening
  /// `holdDeadline` fires the timeout instead.
  private func deadlineDrivingClock(
    drainStarted: AsyncGate,
    holdDeadline: AsyncGate
  ) -> ScriptedClock {
    ScriptedClock { _ in
      drainStarted.open()
      await holdDeadline.wait()
    }
  }

  @Test func closesAdmissionOnShutdownAndDrainsAfterTurnsFinish() async throws {
    // given — a service over lanes holding one turn that outlives its own cancellation.
    let lanes = SessionLaneRegistry()
    let outcome = LaneShutdownOutcome()
    let drainStarted = AsyncGate()
    let holdDeadline = AsyncGate()
    let holdWork = AsyncGate()
    let started = AsyncGate()
    let cancelledObserved = Mutex(false)
    defer { holdWork.open() }

    let service = LaneAdmissionShutdownService(
      lanes: lanes,
      outcome: outcome,
      drainTimeout: .seconds(30),
      clock: deadlineDrivingClock(drainStarted: drainStarted, holdDeadline: holdDeadline),
      logger: TestLog.silent
    )

    let accepted = await lanes.enqueue(sessionID: 1, runID: 1) {
      started.open()
      await holdWork.waitIgnoringCancellation()
      cancelledObserved.withLock { observed in
        observed = Task.isCancelled
      }
    }
    #expect(accepted == .accepted)  // positive: admission is open before shutdown

    // when
    try await testGracefulShutdown { trigger in
      let runTask = Task {
        try await service.run()
      }
      await started.wait()
      trigger.triggerGracefulShutdown()
      await drainStarted.wait()

      // then — a racing enqueue after admission closed is rejected…
      let racing = await lanes.enqueue(sessionID: 2, runID: 2, work: {})
      #expect(racing == .shuttingDown)
      // …and the service is still draining (waiting on the held turn), so nothing is recorded yet.
      #expect(await outcome.value() == nil)

      holdWork.open()
      try await runTask.value
    }

    // then
    #expect(cancelledObserved.withLock { observed in observed } == true)
    #expect(await outcome.value() == .drained)
  }

  @Test func timesOutWithSortedActiveRunIDsWhenTurnsStayInFlight() async throws {
    // given — two turns on distinct sessions that never finish, enqueued out of run-id order.
    let lanes = SessionLaneRegistry()
    let outcome = LaneShutdownOutcome()
    let drainStarted = AsyncGate()
    let holdDeadline = AsyncGate()
    let holdWork = AsyncGate()
    defer { holdWork.open() }

    let service = LaneAdmissionShutdownService(
      lanes: lanes,
      outcome: outcome,
      drainTimeout: .seconds(30),
      clock: deadlineDrivingClock(drainStarted: drainStarted, holdDeadline: holdDeadline),
      logger: TestLog.silent
    )

    for (sessionID, runID) in [(10, 7), (20, 3)] {
      let accepted = await lanes.enqueue(sessionID: Int64(sessionID), runID: Int64(runID)) {
        await holdWork.waitIgnoringCancellation()
      }
      #expect(accepted == .accepted)
    }

    // when
    try await testGracefulShutdown { trigger in
      let runTask = Task {
        try await service.run()
      }
      trigger.triggerGracefulShutdown()
      await drainStarted.wait()
      holdDeadline.open()  // fire the drain deadline while both turns are still in flight
      try await runTask.value
    }

    // then — the timeout reports the still-active runs, sorted (unsorted would be [7, 3]).
    #expect(await outcome.value() == .timedOut(activeRunIDs: [3, 7]))
  }

  @Test(.timeLimit(.minutes(1)))
  func closesAdmissionAndRecordsWhenASiblingServiceFails() async throws {
    // given — the lane-admission service registered LAST behind a sibling that will throw, plus one
    // turn already running. A sibling failure makes the ServiceGroup CANCEL the group rather than
    // shut it down gracefully, so `onGracefulShutdown` never fires: the service must still close
    // admission, deliver cancellation, drain, and record through its `stopAcceptingAndCancel` backstop.
    let lanes = SessionLaneRegistry()
    let outcome = LaneShutdownOutcome()
    let drainStarted = AsyncGate()
    let holdDeadline = AsyncGate()
    let holdWork = AsyncGate()
    let started = AsyncGate()
    let siblingGate = AsyncGate()
    let cancelledObserved = Mutex(false)
    defer { holdWork.open() }
    defer { siblingGate.open() }

    let laneAdmission = LaneAdmissionShutdownService(
      lanes: lanes,
      outcome: outcome,
      drainTimeout: .seconds(30),
      clock: deadlineDrivingClock(drainStarted: drainStarted, holdDeadline: holdDeadline),
      logger: TestLog.silent
    )
    let group = ServiceGroup(
      configuration: ServiceGroupConfiguration(
        services: [FailingGatedService(gate: siblingGate), laneAdmission],
        logger: TestLog.silent
      )
    )

    let accepted = await lanes.enqueue(sessionID: 1, runID: 1) {
      started.open()
      await holdWork.waitIgnoringCancellation()
      cancelledObserved.withLock { observed in
        observed = Task.isCancelled
      }
    }
    #expect(accepted == .accepted)  // positive: admission is open before the failure

    // when — the sibling throws once its turn is in flight, cancelling the group.
    let groupTask = Task {
      try await group.run()
    }
    await started.wait()
    siblingGate.open()
    await drainStarted.wait()

    // then — admission closed via the cancel backstop (not the graceful handler), so a racing
    // enqueue is rejected, and the service is still draining the held turn, so nothing is recorded yet.
    let racing = await lanes.enqueue(sessionID: 2, runID: 2, work: {})
    #expect(racing == .shuttingDown)
    #expect(await outcome.value() == nil)

    holdWork.open()
    // The group re-raises the sibling's failure; awaiting it proves the lane service's run() returned,
    // which is the only place record runs — so a recorded outcome here means the cancellation path
    // reached it.
    await #expect(throws: (any Error).self) {
      try await groupTask.value
    }

    // then — the cancelled turn observed its cancellation, and exactly one outcome landed.
    #expect(cancelledObserved.withLock { observed in observed } == true)
    #expect(await outcome.value() == .drained)
  }

  @Test func drainsImmediatelyWithNoRegisteredTurns() async throws {
    // given — a service over empty lanes; the clock must never be slept on.
    let lanes = SessionLaneRegistry()
    let outcome = LaneShutdownOutcome()
    let service = LaneAdmissionShutdownService(
      lanes: lanes,
      outcome: outcome,
      drainTimeout: .seconds(30),
      clock: ScriptedClock { _ in
        Issue.record("empty lanes must not arm the drain deadline")
      },
      logger: TestLog.silent
    )

    // when
    try await testGracefulShutdown { trigger in
      let runTask = Task {
        try await service.run()
      }
      trigger.triggerGracefulShutdown()
      try await runTask.value
    }

    // then
    #expect(await outcome.value() == .drained)
  }
}

/// A sibling service that parks until its gate opens and then throws, driving the ServiceGroup to
/// cancel the group — the failure path that reaches the lane-admission service as a cancellation
/// rather than a graceful shutdown. Parks ignoring cancellation so it fails only on the test's cue.
private struct FailingGatedService: Service {
  let gate: AsyncGate

  struct SiblingFailure: Error {}

  func run() async throws {
    await gate.waitIgnoringCancellation()
    throw SiblingFailure()
  }
}
