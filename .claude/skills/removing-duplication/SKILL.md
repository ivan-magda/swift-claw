---
name: removing-duplication
description: Use when asked to find and remove duplicated code or duplicated rules in swift-claw, within one module or across modules and layers (DRY pass, consolidation refactor, "устранить дублирование", shared helper extraction), including duplicated validation, retry, path, config, serialization, error-mapping or resource-handling logic.
---

# Removing duplication in swift-claw

Duplication means one rule stated twice: the same domain knowledge, not similar-looking lines.
A merge must preserve behavior on every supported platform (macOS and Linux CI). A difference
you cannot prove is accidental stays separate.

## 1. Before any edit

1. Read `Package.swift` (target edges), `docs/ARCHITECTURE.md` §3.1 (owners), `docs/TESTING.md`.
2. Run `swift test` once and record the actual result. The final run is compared to this one.
3. Create a ledger file in the scratchpad. Every candidate group gets one row (§3).

## 2. Two passes

**Pass 1, per target.** Cover each directory in `Sources/` and `Tests/`. Look for repeated
private helpers, repeated literals that name one thing, and the same guard in several files.

**Pass 2, across targets, by rule.** Search each category in all of `Sources/`:

| Rule | Seeds |
| --- | --- |
| Validation | `guard .* else { throw`, `isEmpty`, `".."`, character-set checks |
| Retry, timeouts | `retry`, `backoff`, `sleep(for:`, `deadline`, `duration(to:` |
| Paths | `resolvingSymlinksInPath`, `standardizedFileURL`, `realpath`, `hasPrefix(` |
| Config, env | `environment[`, `CLAW_`, default values parsed from strings |
| Serialization | `JSONEncoder()`, `JSONDecoder()`, `outputFormatting`, `CanonicalJSON` |
| Errors | `catch`, `StoreError`, `classifyError`, user-facing error copy |
| Resources | `FileHandle`, `open(`, `close(`, `defer`, `O_NOFOLLOW` |

Record leads found outside your current slice as ledger rows marked "hand off". Re-read the
code before acting on any row another agent or an earlier pass wrote.

## 3. Ledger row (every field required)

```
Group:      <id> <the rule in one sentence>
Sites:      <file:line (target)> for every copy
Differences:<inputs, outputs, side effects, errors, platform APIs;
             "none" only after reading all copies>
Intent:     <per difference: commit SHA (`git log -S`, `git log -L`), spec §, or test name;
             else "no evidence">
Decision:   merge | keep separate | hand off
Home:       <existing type/file>; access level; "no new Package.swift edge" verified
Behavior:   identical on macOS and Linux (how proven) | changes (see §4)
Tests:      <existing test per site that fails if the shared rule breaks>,
             or <new test + the mutant it kills>
```

## 4. Decide

Keep separate when any of these hold:
- The copies belong to different domain grammars or owners (repo names vs file names).
- The bytes are persisted, hashed or sent on a wire and differ in any way.
- Each seam maps errors to its own type or message, and sharing would erase that.
- The shared form needs a flag or mode parameter that selects behavior.
- The home would add a target dependency or move module-owned code up without a second consumer.
- It is a single platform call with no rule behind it.
- A test copy serves as an independent oracle for production code.
- An "Intent" field holds evidence that the difference is deliberate.

If the merged code would return a different result for any input on macOS or Linux, the
change is a behavior change, not a refactor. Proving it on one platform is not enough.
Either keep the copies separate and list the group under "Kept separate", or ship the change
in its own commit with a test that fails before it. Foundation path and URL APIs differ
between Darwin and swift-corelibs; prove those on Linux (`docker run swift:6.4.0-noble`) or
keep them separate.

Merge into the owner of the concept: the module that already holds it, `ClawCore` (with `package`
access) for a rule used by several targets, `ClawTestSupport` for test doubles. Callers keep
their own error mapping, defaulted clock or file-manager seams, and domain-typed parameters.

## 5. Implement and recheck

1. Ask the maintainer which branch to use. One commit per merged group.
2. After each group: re-read every former site listed in its row, and run its tests.
3. Second search: run every seed again plus the new symbol's name. New hits become rows.
4. Run `scripts/lint.sh --fix` and inspect its diff. Then run `scripts/lint.sh`, `swift build`
   and `swift test`.
5. Update `docs/ARCHITECTURE.md` in the same commit when a contract names the shared rule.

## 6. PR body

Follow `.github/PULL_REQUEST_TEMPLATE.md`:

- **What changed and why:** one short paragraph per merge: the rule, former sites, new home,
  why behavior is unchanged.
- **Kept separate:** one line per important group: what it is and the evidence for keeping it.
- **Validation:** fill it only after the commands ran. Each line holds a command and the result
  it printed, such as `swift test: <N> tests passed`. A check you did not run reads
  `not run: <reason>`.
