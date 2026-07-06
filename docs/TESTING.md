# swift-claw — Testing

|             |                                                                                                                |
| ----------- | -------------------------------------------------------------------------------------------------------------- |
| **Status**  | Normative testing conventions                                                                                  |
| **Date**    | 2026-07-06                                                                                                     |
| **Owner**   | Ivan Magda                                                                                                     |
| **Related** | [`ARCHITECTURE.md`](./ARCHITECTURE.md) (esp. §12 untrusted data) · [`../CLAUDE.md`](../CLAUDE.md) (code style) |

> **Authority.** This document is the normative guide for what to test and how. It states the principles a test must satisfy to earn its place in the suite, and the swift-claw-specific conventions that apply them. It is a companion to `ARCHITECTURE.md`: that spec says what the system must do; this one says how we prove it keeps doing it. Where a test and this guide disagree, rewrite the test.
>
> This is a _principles_ document, not a review. It deliberately contains no point-in-time audit of the current suite (coverage numbers, lists of tests to delete) — that belongs in a PR or issue and goes stale the moment a test changes.

---

## 1. Why we test

The goal of the suite is **sustainable development speed** — the freedom to refactor and extend the daemon without fear of silent regressions — not a coverage number. A test exists to buy confidence that observable behavior is intact. It follows that **a test has a cost as well as a value**: it must be read, maintained, and kept honest. A test whose upkeep exceeds its fault-detecting value is net-negative and should be deleted, not tolerated. Judge every test on both sides of that ledger.

## 2. The four pillars

A good automated test is defined by four attributes (Khorikov):

1. **Protection against regressions** — it fails when a real fault is introduced. This is the _signal_.
2. **Resistance to refactoring** — it does _not_ fail when internal design changes but behavior is preserved. False failures are _noise_.
3. **Fast feedback** — it runs quickly enough to stay in the edit loop.
4. **Maintainability** — it is small to run and easy to understand.

Pillars 1 and 2 are in tension and together form a **signal-to-noise ratio**. A test that covers a lot but screams on every rename has a terrible ratio and trains the team to ignore the suite. Of the four, **resistance to refactoring is the most important discriminator** between a good test and a bad one: a slow or slightly weaker test is tolerable, but a test that punishes you for improving the code is actively harmful.

## 3. Test behavior, not implementation

This is the root principle; every rule below is downstream of it.

- **Assert observable behavior — an outcome visible from outside the unit — not the steps taken to produce it.** The behavior under test may span several types; the number of classes involved is irrelevant to test design.
- **Coupling a test to implementation detail is the direct cause of false positives.** Asserting _how_ (which private method ran, which collaborator was called in what order) breaks on refactor; asserting _what_ (the returned value, the persisted row, the message enqueued, the error thrown) survives it.
- **Drive the system through its public seam the way a real caller does**, so that a failure implies a genuine break in a contract someone depends on.
- **Confidence through realism**: prefer the arrangement that most resembles real usage, within the speed budget.

For swift-claw this means we assert on the **observable effects** the harness produces: outbox payloads, run-state transitions (§7 FSM), persisted rows, the network-egress list, the taint/sensitivity flags on a context snapshot, and the _typed_ error at a seam — never on private structure or call order.

### 3.1 Assert the effect, not the interaction

In acceptance and integration tests, assert that the effect happened ("a `.done` run and exactly one outbox row exist", "the fetched content is fenced and fed back to the model"), not that a specific method was invoked. Effect-assertions let us rewrite internals without touching the test; interaction-assertions do the opposite. Prefer **state verification over interaction verification**: check _what the result is_, not _how it was made_.

## 4. Isolation and test doubles

The useful question is never "mock or not" — it is **what kind of dependency is this**:

- **Managed dependencies** are implementation details the outside world never observes. For us that is **SQLite via GRDB**. _Do not mock them._ Test against a real in-memory or file-backed database; a mocked store only tests the mock. Real SQLite is the right call for SQL, FTS, migration, trigger, and atomicity tests.
- **Unmanaged dependencies** are observable to the outside world, and their communication pattern _is_ a contract. For us that is the **LLM provider** and **Telegram**. Substitute them at their protocol seam (`LLMProvider`, `ToolDispatching`, `HTTPExecuting`, the Telegram transport) with a scripted double, and — only here — asserting the request we send them is legitimate, because that request is externally observable.

Pick the lightest double that expresses the intent (Meszaros/Fowler taxonomy):

| Double    | What it is                                      | Use when                                                    |
| --------- | ----------------------------------------------- | ----------------------------------------------------------- |
| **Dummy** | fills a parameter, never used                   | satisfying a signature                                      |
| **Stub**  | returns canned answers                          | the SUT needs to _receive_ an input                         |
| **Fake**  | a working, in-memory alternative implementation | you need realistic behavior cheaply — prefer this to a mock |
| **Spy**   | a stub that records how it was called           | you must assert a call that crosses an **unmanaged** seam   |
| **Mock**  | pre-programmed with call expectations           | verifying an unmanaged contract's protocol                  |

A spy or mock that asserts "an _internal_ collaborator was called with X" is a smell: it couples the test to implementation and will break on a behavior-preserving refactor. If X does not cross an unmanaged boundary, assert the resulting state instead.

## 5. Test shape for a long-running daemon

The pyramid-vs-trophy debate is largely definitional (advocates of "fewer unit tests" usually mean _solitary_, mock-isolated ones). The durable conclusion: **suite value comes from test quality, not from a unit-to-integration ratio.** Good tests establish clear boundaries, run fast and reliably, and fail only for useful reasons; arguing percentages is a distraction.

swift-claw is IO- and concurrency-heavy, so a **diamond/honeycomb lean is correct**, not a defect:

- Keep the **pure domain core** (context assembly, budget fitting, FSM transitions, policy gates, parsers, ranking) covered by **fast, sociable unit tests**. This is the widest, cheapest layer and it should stay that way.
- Accept that the behavior worth protecting at the **seams** (router → lane → store → dispatcher, streaming turn, migrations) only exists when several real units run together. Those integration tests are load-bearing; write them against real stores and scripted unmanaged doubles.
- Reserve a **thin acceptance layer** for the end-to-end security and persistence invariants (§12 fencing, SSRF/exfil boundaries, single-owner access, crash recovery).

Do not manufacture solitary unit tests for glue whose only real behavior is the wiring — test the wiring at the seam.

## 6. Stability and determinism

A flaky test — one that passes and fails with no change to code — is worse than no test: it erodes trust in every other result. The three causes and our rules:

- **Order dependency.** Every test builds its own environment and cleans up; none depends on another's residue or on execution order. Use a fresh database per test.
- **Concurrency.** Never synchronize a test with `sleep`/`Task.sleep`. Drive the timing point with an explicit gate/continuation and assert on the **signal** the system already emits (a completion, an outbox row, a published draft), not on a stopwatch. Reuse the existing gate primitives rather than inventing wall-clock windows.
- **Environment.** Keep real time, the real network, and unmanaged third parties out of the deterministic path. Real loopback HTTP servers are acceptable only when the transport itself is under test, marked `.serialized`, and torn down deterministically.

### 6.1 Swift Testing / async specifics

- Use **Swift Testing** (`@Test`, `#expect`, `#require`, `@Suite`). Prefer `#require` to unwrap a precondition so a failure stops the test at the right line rather than trapping later.
- To observe an intermediate async state deterministically, insert **`await Task.yield()`** before the assertion to force the suspension point, instead of sleeping.
- When a test needs deterministic task ordering, pin execution with **`withMainSerialExecutor`** (Swift Concurrency Extras) so intermediate state is observable without a race.
- A bounded poll (loop-until-signal with a ceiling) is a last resort; if used, factor it into one shared helper so the ceiling is tunable in a single place, and prefer awaiting the emitted signal over polling state.

## 7. Readability: DAMP and DRY are not opposites

"DRY for production, DAMP for tests" is a misreading. DRY forbids duplicating **domain knowledge**, not duplicated lines. Apply both, to different parts of a test:

- **DRY the "how-to"** — extract fixtures, builders, and scripted doubles into helpers so mechanics appear once.
- **DAMP the "what"** — keep the scenario narrative (arrange / act / assert) descriptive and legible in the test body. A test should read as a self-contained specification.
- Follow **Given-When-Then**: separate the body with `// given` / `// when` / `// then` (see `CLAUDE.md`).

### 7.1 One source of truth for every value

Do not re-type a value the production code already names. Assert through the **enum `rawValue` or named constant the code emits** — `RunState.done.rawValue`, the budget-cap constant, the `<claw-untrusted>` fence token, the truncation marker — not a duplicated string literal. A rename should touch one place. This is the `CLAUDE.md` "no magic strings / canonical abstractions" rule applied at the test seam.

### 7.2 Do not freeze incidental detail

Pin the load-bearing part of an output, not the whole rendered blob:

- **User-facing copy** (owner notices, `/memory` review blocks, prompts, doctor labels): assert the structural fields that carry meaning (an id, a number, the presence of a marker, the group order), or route the check through the same constant/template the code renders. Do not assert the full literal including emoji and punctuation — that is a change-detector on copy, not a behavior test.
- **Counts, positions, ids:** assert content and containment, and ordering _by key_. Do not pin an assembled-message count, a positional row index, or an autoincrement id (`[1, 2]`) that is incidental to the contract. Keep an exact count only where cardinality is itself the contract (e.g. a guard against spurious rows).
- **Schema shape:** assert a migration produced the required columns via `contains`/`isSuperset`; `PRAGMA table_info` order is not a behavioral contract.

## 8. Measuring test value

- **Coverage is a negative indicator only.** Low coverage reliably flags under-testing; 100% coverage proves nothing about fault detection and is trivially gamed. Do not use coverage as a quality target.
- **The real value signal is mutation-thinking.** Before writing or keeping a test, ask: _what fault would this fail on that no other test would?_ If you can inject a plausible bug into the code the test "covers" and the test still passes, it is not protecting that behavior. A test that cannot kill any mutant is tautological — it tests the framework, the language, or the test double, not our logic.

## 9. The decision rubric

Apply in order, when writing a new test or triaging an existing one:

1. **What fault would this fail on that no other test would?** No answer → do not write it / delete it (it is tautological or redundant).
2. **Would it survive a behavior-preserving refactor?** No → assert the outcome, not the mechanism.
3. **Managed or unmanaged dependency?** Managed (SQLite/GRDB) → use the real thing. Unmanaged (LLM/Telegram) → stub at the protocol seam; assert the outbound contract, never internal call order.
4. **Signal or stopwatch?** Synchronizing on `sleep` → replace with a gate / `Task.yield()` / emitted signal.

## 10. Conventions checklist

A test in this repo:

- [ ] asserts an **observable effect** (outbox payload, run state, persisted row, egress list, typed error), not private structure or call order;
- [ ] uses a **real GRDB store** for anything touching SQL/FTS/migrations/triggers, and a **scripted double at the protocol seam** for the LLM provider and Telegram;
- [ ] references the **enum `rawValue` / named constant** the production code emits, not a duplicated literal;
- [ ] pins the **load-bearing fields** of any rendered output, not the full copy blob or incidental counts/ids;
- [ ] synchronizes on a **gate or emitted signal**, never a `sleep`;
- [ ] builds its **own fresh environment** and cleans up; does not depend on order;
- [ ] reads as a spec: **Given-When-Then**, DAMP narrative, DRY mechanics;
- [ ] would **fail on a real fault** you can name.

---

## Sources

Verified against primary and authoritative secondary sources:

- Vladimir Khorikov, _Unit Testing: Principles, Practices, and Patterns_ — the four pillars; the signal-to-noise ratio; resistance-to-refactoring as the primary discriminator; managed vs. unmanaged dependencies; coverage as a negative-only indicator; deleting net-negative tests.
- Martin Fowler, _Mocks Aren't Stubs_ and _On the Diverse And Fantastical Shapes of Testing_ — the test-double taxonomy; mockist vs. classicist; state vs. behavior verification; the pyramid-vs-trophy dispute as largely definitional (solitary vs. sociable).
- _Software Engineering at Google_, ch. 12 (Unit Testing) — test through the public API; test behavior not implementation; brittleness from over-specification.
- Kent C. Dodds, _The Testing Trophy_ — confidence-through-realism; integration as the primary layer; static analysis as the base.
- Codecov, _Mutation testing_ — coverage as a vanity metric; mutation testing as the true value signal.
- Datadog, _Flaky tests_ — the order / concurrency / environment taxonomy of flakiness.
- Shai Yallin, _Fake Don't Mock_; enterprisecraftsmanship, _DRY and DAMP in unit tests_.
- Antoine van der Lee, _Unit testing async/await_ — `Task.yield()` before assertions; `withMainSerialExecutor` for deterministic ordering.
