---
name: pragmatic-testing
description: Decides whether to write a test, what it asserts, which test double it uses, and how many tests a change needs. Load before adding, changing, reviewing, or deleting any test or test double, when auditing existing tests for low value, and when proving that a test prune lost no protection.
---

# Pragmatic Testing

Tests exist so we can change the product and still ship it. A test that fails on every
refactor and never catches a real bug makes change harder.

Most of these ideas come from Orta Therox's
[*Pragmatic Testing*](https://github.com/orta/pragmatic-testing). Aim for enough, not
perfect. Don't test every `if`. Paint with a wide brush first and keep the fine brush for
the edges. The examples are Swift, but the rules apply in any language.

## Earn-its-place check

Answer these before you write a test. If you can't answer them, don't write it.

1. **Which bug does it catch?** Name a plausible one-line mistake in production code that
   makes this test fail. Put it in the test name or a short comment. "Someone deletes the
   function" does not count. Pick a mistake that a refactor or a wrong fix could
   introduce.
2. **What ships broken if you delete it?** If another test or the compiler would already
   fail, this one is redundant.
3. **Does it survive a refactor that keeps behaviour?** If it breaks when the internals
   change and the observable result stays the same, it pins the implementation. Rewrite
   it against the result. Scheduling controls are the exception. See Doubles.

## Expected values come from the product rule

Write expected values as literals taken from the product rule. Put inputs on the
boundary, and add a comment when the rule isn't obvious:

```swift
// Exact saving is 37.58%. We round down so we never overstate a discount.
#expect(viewModel.annualSavingsText == "Save 37%")
```

Never derive the expected value from the code under test.

- Don't branch on the test's parameters to compute the expected value. That copies the
  production branching, and if both are wrong the test still passes.
- Don't call the production formatter or helper to build the expected string.
- Don't assert that a mock's return value comes back unchanged through a pass-through.

If you got the literal by running the code and copying the output, you have a
characterization test. That is a fine safety net for a refactor, but say so, and check
the number against the rule by hand before you commit it.

If the literal depends on locale or OS formatting, the formatting isn't yours to test.
Check your input to the formatter, or skip it.

## One owner per contract

Test each rule once, at the lowest layer that owns it. From lowest to highest, the layers
are domain logic, state or presenter, and view model. A higher layer gets one wiring
test, such as "forwards X, shows the result". It does not rerun the rule's cases.

- **Wide brush.** One whole-value assertion on the state or result checks every field at
  once. Make your types `Equatable` so you can write it.
- **Fine brush.** One parameterized test covers the inputs that change the outcome, such
  as boundaries, empty input, and failure. A parameterized test counts as one test.
- The same tests cloned across several screens point to cloned production code. Extract
  the shared helper and test it once.

## Doubles

Pick the cheapest double that answers the question the test asks.

| The test needs | Use |
|---|---|
| Return values, thrown errors, verifying an effect | A generated mock, such as Mockable |
| One call parked mid-flight, released by the test | A thin wrapper around the mock that suspends that call until the test resumes it |
| State across calls, streams held open, ordering | One controllable fake per protocol, kept next to the protocol behind a debug flag or in a test-support target |
| Behaviour that *is* the implementation: DB constraints, file atomicity, parser output | The real implementation, in an integration test |

- **One fake per protocol.** Extend it before you write another. Write a test-local
  double only for a control the shared fake lacks, and name that control in a one-line
  comment.
- **An inert stand-in is no reason for a new double.** If a parameter just needs
  *something*, use a relaxed mock or the shared fake.
- **A double may control scheduling but not semantics.** Parking a call, counting writes,
  and firing a callback synchronously are all fine. They stay fine when they follow
  internal suspension points, because the race is the behaviour under test. A double that
  re-implements a product rule makes the test check the double.
- **Don't mirror real semantics in a fake.** A fake that evicts or encodes the way the
  real type does means you want an integration test against the real type.
- **Keep the doc comment current.** A double's doc comment describes what the tests drive
  it to do.
- **Third copy rule.** When the same test-local double appears in a third file, promote
  it and delete the copies.

### Stub freely, verify only effects

Stubs are fine. Keep the ones that define the scenario in the test body. Verify only the
effects that a user or the system can observe.

- **Verify** a delete, a file or DB write, a purchase, a network mutation, an analytics
  event, or a navigation. "Called never" on an irreversible effect after a failure earns
  its place, because the user can't undo that bug.
- **Don't verify** reads and fetches. "Called once" on a read fails on a harmless refetch
  and catches nothing a user sees. The exception is a test about caching, single-flight,
  or debounce.
- Don't repeat a verification that an ordered call log in the same test already proves.

## Test budget

Most behaviour changes need **1 to 3 tests**. State a reason before you write a fourth.
The budget has no cap for concurrency and ordering, persistence and recovery, or money
and access gating. In concurrent code, each interleaving that matters is its own
behaviour.

Writing no test is a valid outcome for pure wiring, one-line pass-throughs, restated
enums or `switch` statements, memberwise inits, constants, defaults, and view
composition. When you skip a test, name the existing test or compiler check that would
catch a mistake. Never skip the test for a new conditional with product meaning, a race,
persistence, or money.

## Bug reproductions

1. Reproduce the bug with a focused test at the owning layer. **Watch it fail on the
   unfixed code, for the reported reason.** A reproduction you never saw fail proves only
   that the mock works.
2. Fix the bug at the owning layer.
3. Decide what happens to the test, and say which option you chose.
   - **Keep** it if it guards a plausible regression that nothing else covers.
   - **Fold** it into a parameterized test as a new row, or into a widened assertion.
   - **Discard** it if it was only a diagnostic.

Ordinary tests need no test-first ritual. Write the test with the change, then break the
production line once and confirm the test goes red. Bug reproductions are different.
Stash the fix and run the reproduction against the unfixed code, because re-breaking the
code afterwards only tests your theory of the bug.

## Smells

| Smell | Example or fix |
|---|---|
| A mock returns X and the test asserts X | The repository mock returns three items and the test expects the same three back |
| The production logic computes the expected value | The test runs the same `if`/`else`, or the same formatter, to build its expectation |
| A double re-implements product logic | A mock queue has its own retry and back-off rule, and the test checks that rule |
| A test restates a one-line `switch` or computed property | Asserting that the loading state has no items, when its definition says it has no items |
| An assert that can't fail | Setting a value to nil and then asserting it is nil. Asserting the contents of your own fixture |
| Wait for X, then assert X | Fine only when the assert is wider, such as the whole state |
| Call counts on reads | "Fetch was called once" in a load test |
| Near-identical tests that differ in one input | Merge them into one parameterized test |
| Sleep, then assert | Sleeping 0.7 s and asserting "at least one". Await the completion or a signal instead |
| Pinning every intermediate emission | Pin only the states the UI or the contract relies on |
| A production seam that exists only for a test | A "for testing" hook. Move the test to the layer that owns the behaviour |

## Audit mode

Report first, edit second.

- **Give evidence for each candidate.** List the test name, the bug it claims to catch,
  the stronger test that remains, and any production seam that deleting it would free up.
  Search the git history to see whether a bug fix introduced it.
- **Some tests stay even when they look like implementation tests.** Keep race and hang
  proofs, the only test on a filesystem or DB failure mode, regressions from real bugs,
  and tests of observable ordering.
- **If a weak test is the only test, rewrite it.** A test that sleeps and asserts loosely
  may be the only one that reaches a path. Deleting it removes the protection along with
  the weakness.
- **Audit doubles too.** Replace a hand-written double with the generated mock or the
  shared fake, keep it with a comment that names the missing control, or merge it with
  its duplicates.
- **Fix the production cause first** when a cluster of low-value tests mirrors duplicated
  production code.
- **Never weaken a test** only to make the deletion count look better.
- Keep each change to one coherent batch.

### Prove the prune

Every batch that deletes, merges, or rewrites tests ends with proof that the remaining
tests still catch what the old ones caught. The agent that pruned must not grade itself.
Run the numbers, or hand them to a separate reviewer.

1. **Coverage first.** Compare per-function coverage before and after the prune. In
   Xcode, run the tests with code coverage enabled. Without the flag the report comes
   back empty and nothing warns you. Read each result bundle with `xccov`. Run the
   "before" side in a worktree at the merge base. Flag every function that drops to 0%.
   If you have a complexity tool, also flag every function that newly crosses a CRAP
   score of 30. Each flagged function needs a rewritten test or a stated reason. A
   deleted test that restated a `switch` is an expected "no test needed" drop, so say so.
   Every other per-function drop goes to step 2.
2. **Mutants where protection moved.** Write mutants only for functions that lost
   coverage or whose tests changed. Use up to about six one-line mutants, such as a
   flipped comparison, a dropped filter, an early return, or a negated guard. Start with
   the bug each removed test claimed to catch. Apply one mutant at a time, and confirm
   each restore by file hash.
3. **Tie the proof to the deletion.** Before the prune, record which tests kill each
   mutant. At least one killer must be a test this batch removes or rewrites, or the
   mutant proves nothing about the prune. After the prune, name the new killer.
4. **Gate.** The remaining tests must kill every mutant that the old tests killed. If a
   mutant now survives, restore or rewrite a test. A mutant that survives on both sides
   is an old gap. Add a test for it only if the test passes the earn-its-place check, and
   watch the test fail by re-applying the mutant.
5. **Report.** Give a table of each mutant with its killer before and after, plus the
   coverage drops and their reasons. If you wrote tests after you saw the survivors, say
   so. The score then only fits that sample of mutants.

CRAP stands for Change Risk Anti-Patterns. It combines complexity and coverage:

```text
CRAP = complexity² × (1 − coverage)³ + complexity
```

The Xcode commands for step 1:

```bash
xcodebuild test -enableCodeCoverage YES ...
xcrun xccov view --report --json Test.xcresult
```
