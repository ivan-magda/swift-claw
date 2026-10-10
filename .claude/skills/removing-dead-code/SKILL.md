---
name: removing-dead-code
description: Use when asked to find, audit or remove dead, unused or unreachable code in swift-claw, repository-wide or in one module ("dead code cleanup", "удалить неиспользуемый код", unused declarations, imports, target dependencies, resources, fixtures, scripts or config), or when judging whether such a cleanup is complete before its PR.
---

# Removing dead code in swift-claw

A scanner's output is a list of leads. It is never the verdict and never the complete set.
A cleanup is finished when the completeness sweep (§5) finds nothing new, not when the
scanner's list is empty or the build passes.

Run every command from the repository root, with `S=.claude/skills/removing-dead-code/scripts`
for the skill's own scripts and output in the session scratchpad. `scripts/check-dead-code.py` is
the repository gate. Each script's header documents its flags.

| Command | Time | Finds |
| --- | --- | --- |
| `python3 -I scripts/check-dead-code.py` | seconds | target dependencies nothing imports and files nothing names; `scripts/lint.sh` runs it too |
| `bash $S/periphery_scan.sh OUT` | 5–10 min | Periphery with and without tests; `OUT/report.md` with false-positive hints |
| `python3 -I $S/prune_imports.py --work DIR --base REF` | ~2 min per module | imports the compiler proves removable, including modules Periphery never reports |
| `python3 -I $S/prune_imports.py --work DIR --check-only --base REF` | ~1 min | files that compile only by borrowing another file's import |

`periphery_scan.sh` builds its own index store: the default build backend writes none, so a
plain `periphery scan` fails with "index store path does not exist".

The last three commands build the whole package, the pruner once per module. Run them one at a
time, never in parallel: two at once take longer than the same two in sequence. Reuse one fixed
`--work` or `OUT` directory per command, so a rerun builds incrementally.

## Modes

**Quick scan** (audit, "find dead code"): run `scripts/check-dead-code.py` and
`periphery_scan.sh`, then report the triage grouped as in §2. No edits.

**Full cleanup** (remove): stages 1–6 below, on a feature branch.

## 1. Baseline

Read `Package.swift`, `docs/ARCHITECTURE.md` §3.1 and `docs/TESTING.md`. Run `swift test` and
record the result. Create a ledger in the scratchpad with one row per candidate:

`id | location | kind | scanner hint | verdict | evidence (file:line or command) | researcher result | orphans removed`

Verdict is one of DELETE, KEEP, AMBIGUOUS, OUT-OF-SCOPE. Every row needs evidence you read.

## 2. Triage

| The scanner says | Usually in this repo | The check that decides |
| --- | --- | --- |
| Property unused or assign-only in an `Encodable` type | Serialized to the wire or into a digest | Find the encoder; tests that decode the body |
| Field assign-only in an `Equatable`/`Hashable` type | Takes part in `==` | Synthesized conformance |
| `@Test(arguments:)` function, its argument enum, its parameter labels, helpers only it calls | Swift Testing discovers them at runtime | The `@Test` attribute |
| Case of a `CaseIterable` enum | Reached through `allCases` | `.allCases` users |
| Unused parameter | Signature fixed by a protocol, override or function-typed value | `Self.function` passed as an argument |
| Protocol requirement nobody calls through the protocol | Documented contract | ARCHITECTURE.md → AMBIGUOUS |
| Production declaration only tests reach | Seam (`ForTesting`, documented, defaulted clock/FileManager), contract, or convenience | See "Test-only code" below |
| Unused imports | Covers only modules Periphery indexed | `prune_imports.py` (§5) |

**Test-only code.** A production declaration that a test calls is KEEP unless the only tests
calling it exist to test it; then it and those tests form one candidate. A deletion that makes
you rewrite another test is not a deletion: mark it AMBIGUOUS. `git log -S'<name>' -- Sources`
showing a removed production caller is a lead, not proof: a sibling seam added in the same
commit, a doc comment or a `ForTesting` name means it was kept on purpose. Search
`docs/ARCHITECTURE.md` for the name before calling anything unused.

Keep by default: migrations, legacy-data compatibility paths, contracts named in
`docs/ARCHITECTURE.md`, resources loaded by a computed name, files tools discover by
convention. An unwired enum case or protocol member named by a spec is AMBIGUOUS: report it.

## 3. Independent researcher, before each deletion group

Dispatch a fresh read-only subagent per group. Its brief has these parts, in this order:

1. **Candidates**: exact file:line list and the repository path. It must not build into the
   shared `.build`; it uses `--scratch-path` in the scratchpad if it builds.
2. **Still needed?** For each candidate: direct and indirect uses; registration by string,
   reflection, macro or runtime; public contracts and documented APIs; `#if` branches and Linux;
   CI, scripts, docs; `git log -S` for an unfinished migration. "No grep hits" is not evidence.
3. **Left behind?** What applying this group leaves: declarations or target dependencies with no
   remaining user, files that would compile only by borrowing another file's import, test files
   that no longer touch their target's module, names and doc comments that stop describing the
   remaining use, unused imports in the touched files that the scanner did not list.
4. **Report shape**: per candidate `NEEDED: scenario + evidence` or `NO USE FOUND: checks run`;
   then the part 3 findings with file:line; then what it could not verify.

Open the cited code before acting on any researcher claim.

## 4. Apply

Delete only rows with DELETE and NO USE FOUND. Remove the orphans part 3 named. Rename or
re-document anything whose remaining use changed.

## 5. Completeness sweep (gate, repeat until nothing new)

1. `prune_imports.py --work DIR --base <branch base>`, then `git apply DIR/prune.patch`. It
   keeps any import a file uses through members, even when the file compiles without it.
2. Repository-wide task: `prune_imports.py --work DIR --all --modules deps` (package-dependency
   modules, Testing and Synchronization; Foundation, OS modules and Crypto stay out because a
   macOS build cannot prove Linux). It takes about an hour: run it last and alone.
3. `prune_imports.py --work DIR --check-only --base <branch base>`, then the same check on a
   worktree of the base commit. A file listed now but not on base borrows because of a hand
   edit: put back the import its error names. Files listed on both are pre-existing: note them
   in the PR.
4. `scripts/check-dead-code.py` again: removed imports orphan target dependencies. Keep a
   finding only with a reason in `BuildTools/dead-code-allowlist.txt`.
5. Every edited test file still uses the module its target tests; otherwise move the test to the
   owning target (TESTING.md §9.1) and check it against that target's existing tests.
6. `git grep` each removed name in `docs/`, `scripts/`, `.github/`, `.agents/`.
7. `periphery_scan.sh` again: a deletion exposes the next layer (a gate only its reader used).

## 6. Verify and publish

`scripts/lint.sh --fix`, inspect, run `--fix` again (no change), `scripts/lint.sh`, `swift build`,
full `swift test`. Linux runs in CI; say so. The PR lists each deletion with its evidence and
researcher result, the kept-on-purpose categories, and a short AMBIGUOUS list.

## Red flags

| Thought | Reality |
| --- | --- |
| "I removed every import Periphery listed, so imports are done." | It never reports GRDB, Logging or Testing imports and misses some project ones. Run §5. |
| "It compiles without the import, so the import is unused." | The file may borrow it. Run `--check-only`. |
| "Build and tests pass, so the cleanup is complete." | Passing says nothing about leftovers. Run §5. |
| "The researcher found no use, apply the group." | Read part 3 of its report and open each cited line first. |
| "Only tests use it, so it's dead." | Seams and contracts live there. Apply the test-only rule in §2. |
