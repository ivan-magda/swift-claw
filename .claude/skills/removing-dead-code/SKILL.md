---
name: removing-dead-code
description: Use when asked to find, audit or remove dead, unused or unreachable code in a Swift package or Xcode app, repository-wide or in one module ("dead code cleanup", "удалить неиспользуемый код", unused declarations, imports, target dependencies, resources, assets or files), or when judging whether such a cleanup is complete before its PR. Needs the swift-dead-code CLI.
---

# Removing dead code with swift-dead-code

The CLI finds candidates deterministically; you decide what the tool cannot: whether a
finding is a seam, a contract or AMBIGUOUS, and whether a deletion leaves anything behind. A
scanner's list is a set of leads, never the verdict and never the complete set. A cleanup is
finished when the completeness sweep (§5) finds nothing new, not when a list is empty or the
build passes.

If `swift-dead-code` is missing, install it with `brew install ivan-magda/tap/swift-dead-code`;
`scan` also needs Periphery 3.8.0
([install](https://github.com/ivan-magda/swift-dead-code#install)).

Run every command from the project root. `.deadcode.yml` there holds the project's settings:
schemes, test support, allowlist, baseline path, contract documents. Without one, run
`swift-dead-code init > .deadcode.yml` and fill it in: an Xcode project's schemes and
`builds`, test support targets, `module_names` for a product whose modules have other names
(an umbrella product such as `SwiftToolsSupport-auto`), and `periphery.arguments:
[--retain-public]` for a library. Commit it in a cleanup; in an audit, leave it uncommitted.
Keep output in a scratch directory outside the project, and reuse one directory per command so
reruns build incrementally.

| Command | Time | Finds |
| --- | --- | --- |
| `swift-dead-code check --report` | seconds | target dependencies nothing imports; files and assets nothing names |
| `swift-dead-code scan --output OUT` | minutes | Periphery with and without test code; `OUT/report.md` with false-positive hints |
| `swift-dead-code prune-imports --work DIR --base REF` | minutes per module | imports the compiler proves removable, including modules Periphery never reports |
| `swift-dead-code prune-imports --work DIR --check-only --base REF` | minutes | files that compile only by borrowing another file's import |
| `swift-dead-code baseline OUT/all.json OUT/prod.json` | seconds | Periphery findings the recorded backlog lacks |
| `swift-dead-code describe` | seconds | the targets, test code and dependencies the tool sees |

Read `describe` first on an unfamiliar project: if a target is missing, a test target counts
as product code, or a module name is wrong, fix `.deadcode.yml` (`test_support`,
`module_names`, `project.schemes`) and run `describe` and `check` again before trusting any
finding.
For a library whose public API others use, set `periphery.arguments: [--retain-public]`:
without it every public declaration the package itself does not call looks unused.
`scan` and `prune-imports` build in a copy of the project and take a machine-wide lock: run
them one at a time, never in parallel. They never write into the working tree; the pruner's
result is a patch you apply yourself.

Results hold only for the platforms and build configurations that were built. Code behind
`#if os(...)`, another scheme or another configuration is invisible to a scan that did not
build it; `builds` in `.deadcode.yml` scans several and keeps only what none of them uses.

Product code comes first: with `--base` or `--all`, the pruner skips test code. Pass
`--include-tests` only when the task asks for test code or the branch edits test files, and only
after a run without it: a failing test file makes the pruner keep a module everywhere.

## Modes

**Quick scan** (audit, "find dead code"): `check --report`, `scan`, and, when the project has a
baseline file, `baseline OUT/all.json OUT/prod.json`; without one, every finding is new. Report
the findings grouped by the rows of the §2 table, each with a verdict from §1 and its
evidence, new ones marked. No edits besides an uncommitted `.deadcode.yml`: suggest allowlist
and baseline entries instead of writing them.

**Full cleanup** (remove): stages 1–6 below, on a feature branch.

## 1. Baseline

Read the project's manifest or project file, the documents `docs.contracts` names (or the
project's `AGENTS.md`/`CLAUDE.md`), and how it runs its tests. Build and run the tests; record
the result. Create a ledger in your scratch directory with one row per candidate:

`id | location | kind | scanner hint | verdict | evidence (file:line or command) | researcher result | orphans removed`

Verdict is one of DELETE, KEEP, AMBIGUOUS, OUT-OF-SCOPE. Every row needs evidence you read.

## 2. Triage

`report.md` notes point at the check that decides. A row without notes still needs every
check.

| The scanner says | Often | The check that decides |
| --- | --- | --- |
| Property unused or assign-only in a Codable, Equatable or Hashable type | The scan retains these by default; a conformance in another file escaped it | The encoder, decoder or `==` |
| Parameter of a `@Test(arguments:)` function | Swift Testing passes every argument, read or not | The `@Test` attribute |
| Case of a `CaseIterable` enum, or a `CodingKeys` case | Reached through `allCases` or Codable synthesis | `.allCases` users; the coded type |
| Unused parameter | Signature fixed by a protocol, override or function-typed value | The protocol or the call site that passes the function |
| Protocol requirement nobody calls through the protocol | Documented contract or test seam | The contract documents → AMBIGUOUS |
| `@IBAction`, `@IBOutlet` | Connected in a storyboard or XIB the scan did not read | The nib files, and nibs loaded by name |
| `@objc`, `dynamic`, a name in a string or plist | Selector, KVO, `NSClassFromString`, `NSExtensionPrincipalClass` | The string or plist the note names |
| `@main`, App Intents, widgets, extension principal types | The system finds them | The target's Info.plist and extension point |
| SwiftUI previews and their mock data | Design-time only | Whether the project keeps previews |
| Property read through `$name` | Projected values index separately | The `$name` use the note names |
| A protocol nothing uses as a type, and a row per conformance | A marker for code generators or runtime discovery, or an abstraction left with one conformer | Generator templates and runtime lookups; decide once for the protocol and its conformances |
| Production declaration only tests reach | Seam, contract, or convenience | "Test-only code" below |
| A type another target with the same module name also declares | Two copies merged in one index, which loses one copy's calls; `scan` confirms per build, but a copy that shares a USR or a scheme building both twins still merges | Callers in this file and in that target's copy |
| Unused imports | Covers only modules Periphery indexed | `prune-imports` (§5) |

**Test-only code.** A production declaration that a test calls is KEEP unless the only tests
calling it exist to test it; then it and those tests form one candidate. A deletion that makes
you rewrite another test is not a deletion: mark it AMBIGUOUS. `git log -S'<name>'` on product
code showing a removed production caller is a lead, not proof: a sibling seam added in the same
commit, a doc comment or a `ForTesting` name means it was kept on purpose. Search the contract
documents for the name before calling anything unused.

Keep by default: migrations, legacy-data compatibility paths, documented contracts, public API
of a library others consume, resources loaded by a computed name, files tools discover by
convention. An unwired enum case or protocol member that a spec names is AMBIGUOUS: report it.

A KEEP that Periphery reports goes into the baseline with `baseline --write`. Product code
carries no `periphery:ignore` comments. Never add a DELETE row to the baseline. A KEEP from
`check` goes into the allowlist in `.deadcode.yml`, with its reason.

## 3. Independent researcher, before each deletion group

Dispatch a fresh read-only subagent per group. Its brief has these parts, in this order:

1. **Candidates**: exact file:line list and the project path. It must not build into the
   project; if it builds, it uses its own scratch or DerivedData path.
2. **Still needed?** For each candidate: direct and indirect uses; registration by string,
   reflection, macro, Interface Builder, Info.plist or the runtime; public contracts and
   documented APIs; other targets, schemes, configurations and `#if` branches; CI, scripts and
   docs; `git log -S` for an unfinished migration. "No grep hits" is not evidence.
3. **Left behind?** What applying this group leaves: declarations, target dependencies, assets
   or files with no remaining user; files that would compile only by borrowing another file's
   import; test files that no longer touch their target's module; names and doc comments that
   stop describing the remaining use; unused imports in the touched files.
4. **Report shape**: per candidate `NEEDED: scenario + evidence` or `NO USE FOUND: checks run`;
   then the part 3 findings with file:line; then what it could not verify.

Open the cited code before acting on any researcher claim.

## 4. Apply

Delete only rows with DELETE and NO USE FOUND. Remove the orphans part 3 named. Rename or
re-document anything whose remaining use changed.

## 5. Completeness sweep (gate, repeat until nothing new)

1. `prune-imports --work DIR --base <branch base>`, then `git apply DIR/prune.patch`. It keeps
   any import a file uses through members, even when the file compiles without it. A "Not
   checked" line names targets no configured build compiles: add a scheme or build for them
   in `.deadcode.yml` and run again.
2. Repository-wide task: `prune-imports --work DIR --all --modules deps` (dependency modules
   plus the configured toolchain modules; platform modules stay out because one platform's
   build cannot prove another's). Run it last and alone: it takes one build per module.
3. `prune-imports --work DIR --check-only --base <branch base>`, then, in a clone of the base
   commit (`git clone --local . <scratch>/base && git -C <scratch>/base checkout <base>`; copy
   `.deadcode.yml` there if base has none), `prune-imports --project-root <scratch>/base --work DIR2
   --check-only <the listed files that exist on base>`: `--base` would select nothing there. A
   file listed now but not on base borrows because of a hand edit: put back the import its
   error names. Files listed on both are pre-existing: note them in the PR. An exit
   with `not checked: <targets>` means a dependency failed to build or no build covers the
   target: that is no result, so fix the build or the configuration first.
4. `check` again: removed imports orphan target dependencies, deletions orphan assets and
   files. Keep a finding only with a reason in the allowlist.
5. Every edited test file still uses the module its target tests; otherwise move the test to
   the owning target's tests.
6. `git grep` each removed name in docs, scripts, CI configuration and agent instructions.
7. `scan` again: a deletion exposes the next layer (a gate only its reader used). Then
   `baseline --write` on the new scans; its diff must only remove entries.

## 6. Verify and publish

Run the project's lint, build and full test suite for every scheme and configuration the
cleanup touched. Say which platforms you could not build. The PR lists each deletion with its
evidence and researcher result, the kept-on-purpose categories, and a short AMBIGUOUS list.

## Red flags

| Thought | Reality |
| --- | --- |
| "I removed every import Periphery listed, so imports are done." | It never reports package-dependency or toolchain imports. Run §5. |
| "It compiles without the import, so the import is unused." | The file may borrow it. Run `--check-only`. |
| "Build and tests pass, so the cleanup is complete." | Passing says nothing about leftovers. Run §5. |
| "The researcher found no use, apply the group." | Read part 3 of its report and open each cited line first. |
| "Only tests use it, so it's dead." | Seams and contracts live there. Apply the test-only rule in §2. |
| "The scan is clean on the iOS scheme." | The macOS scheme, extensions and other configurations may use it. |
