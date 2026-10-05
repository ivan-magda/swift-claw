# Verification lessons

Use [TESTING.md](../../docs/TESTING.md) for test design and
[LOCAL_DEV.md](../../docs/LOCAL_DEV.md) for current commands and acceptance gates.
These notes retain investigation lessons from earlier sessions, reviewed on 2026-10-05.

## Evidence before a conclusion

- Trace the real production path before assigning severity. Include persistence order,
  retry, restart reconciliation, and recovery paths before calling a failure permanent.
- Confirm an experiment changed what it claims to change. A stash of an already-committed fix
  does not remove the fix; verify the source before interpreting a mutation test result.
- Check exit codes and tool output, not just the command you intended to run. Inspect staged
  paths and the resulting commit when Git operations are part of the experiment.
- A single successful timing-sensitive run does not establish a safe timeout or remove a race.
- Name what was not tested. Reading code, a skipped acceptance test, and a timed-out process
  are not evidence that the corresponding gate passed.

## Hangs and test timings

- Give test processes an external deadline, especially during hang diagnosis. Build separately
  from execution where needed to identify the failing phase. Narrow a hang by suite and then test
  instead of repeatedly launching the full suite. Use the current commands in the development guide.
- A Swift Testing time limit can report a suspended test without releasing its process. Diagnose
  leaked test helpers and build locks before starting another run. Stop only processes confirmed
  to belong to your run; do not use a blanket kill against other sessions' helpers.
- Never block a cooperative executor thread. The traps and supported alternatives are in
  [TESTING.md §6.1](../../docs/TESTING.md#61-swift-testing--async-specifics). Exercise low-core
  conditions when investigating a CI-only hang.
- Match the process environment in a reproduction. A reaping PID 1 can hide an orphan/zombie
  bug seen in a non-reaping CI container. Record the image, CPU allowance, process tree, and
  scratch directory rather than assuming a developer container is equivalent.
- Full parallel-run durations include contention. Remeasure the affected suite in isolation
  before optimizing it, and distinguish build time from test time. Historical suite counts and
  elapsed times are not current performance budgets.
- Keep signal-based synchronization and bounded failure cleanup. Do not turn a throttled loop
  into a busy loop with a no-op sleep double. Use the existing test support and the test-intent
  and redundancy checks in `TESTING.md`.

## Retired workaround: swift-subprocess 0.5.0

The 2026-07-12 sandbox investigation recorded a process-exit deadlock in version 0.5.0:
an `atexit` shutdown joined a worker waiting in `WorkQueue.dequeue()`. Test bodies could finish
while the helper stayed alive, so the timeout status alone did not describe the test assertions.

The project now pins 1.0.0 in [Package.swift](../../Package.swift). The old instruction to accept
streamed green assertions as a successful run is retired. A timeout remains a failed or incomplete
verification run. If exit hangs recur, investigate the current version and owned process tree;
do not assume the historical diagnosis still applies.

## Formatter suppressions

Use [CODE_STYLE.md](../../docs/CODE_STYLE.md) and the pinned toolchain. Earlier SwiftLint versions
reported optional-collection/optional-boolean violations on the return-type line of a multiline
signature, while complexity/body-length violations pointed at `func`. Check the actual diagnostic
before placing a suppression; a `disable:next` above `func` may not cover the return-type line.
Keep suppressions narrow and verify them with the repository lint gate. Older notes about
formatter commands or disabled rules do not override the current configuration.
