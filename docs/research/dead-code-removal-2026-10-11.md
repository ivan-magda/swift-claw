# Dead Code Removal for a Swift 6 / SwiftPM Codebase: State of the Art, Tooling Limits, and What to Adopt (October 2026)

Your setup is mostly on the right track. What it lacks is not a better scanner but a better **verification and configuration model**. Almost every pain point you list traces back to one cause: you treat a single build of a single configuration on one platform (macOS, debug, one index store) as the definition of "used". The industry systems that delete code at scale (Google's Sensenmann, Meta's SCARF) do it differently. They combine a whole-program dependency graph with an independent liveness signal, send every deletion to a human owner, and treat platform and configuration coverage as part of the analysis rather than an afterthought. Two developments also change the Swift picture this year. The open-source Periphery repository was archived in August 2026 when the tool went commercial.\[1\] And the Swift 6.4 compiler now has a named `UnusedImportAccess` diagnostic group and source-level warning control (SE-0522), but it still has **no general "unused import" warning** and SwiftPM has **no unused-target-dependency check**.

## TL;DR

- **Keep your architecture, fix its inputs.** A static index-based scanner (Periphery), a deterministic manifest/import lint for target dependencies, and human or agent review of each candidate is the established pattern. What is missing is (a) scanning every platform and configuration you ship and intersecting the results, (b) a checked-in baseline with a ratchet instead of repeated full cleanups, and (c) a verification step that goes beyond "it builds on macOS" (Linux release build, public API diff, symbol diff).
- **Swift tooling in October 2026:** open-source Periphery 3.8.0 (July 2026) is the last MIT release before the repo was archived, and development continues as the commercial Periphery Pro, now in a free open beta. SwiftLint's `unused_import` analyzer rule still needs compiler logs and still has module-attribution false positives. The compiler gives you SE-0444 `MemberImportVisibility`, SE-0409 import access levels with an "unused public import" warning (the `UnusedImportAccess` group in 6.4), SE-0443/SE-0480 warning control and SE-0522 `@diagnose`, but no general unused-import warning. SwiftPM only checks the opposite direction (undeclared dependencies), and that check is not supported under the new Swift Build backend.
- **LLM agents are useful as proposers and explainers, not as verifiers.** The best-supported results tie the model to program analysis plus build/test gates. Google's migration work, Meta's graph-driven SCARF, and the Tencent study where an LLM agent with path analysis filtered 94–98% of false alarms all follow this shape. Adversarial "refute" agents do kill many weak candidates, but documented field reports show agent panels unanimously endorsing false conclusions. Your skeptic agent is reasonable, but it must be subordinate to mechanical checks.

## Key Findings

**ESTABLISHED PRACTICE**
- Whole-program reachability over a dependency graph plus an exclusion list and owner review is how Google and Meta delete code at scale. Runtime usage signals are added where available.
- Index-store-based declaration analysis (Periphery) is the de facto Swift tool. Its accuracy is bounded by what was compiled: one platform, one configuration, the targets that were built.\[1\]
- Unused-dependency detection in other ecosystems has converged on fast, compile-free, manifest-plus-source static analysis with per-entry ignore metadata (cargo-shear, Knip). Slow build-based tools are kept as occasional backstops.\[2\]\[3\]
- Baselines/ratchets, allowlists with reasons, and running the analysis once per build configuration and intersecting the results are standard advice from tool authors. Go's `deadcode` documentation, for example, says this explicitly.\[4\]

**EXPERIMENTAL / FRONTIER**
- LLM-proposed deletions with mechanical verification gates (DoorDash flag cleanup, Periphery Pro's `agent-prompt` output, "verifier-budgeted" deletion research).\[5\]\[6\]\[7\]
- Multi-agent adversarial verification ("refute-or-promote") and LLM-as-judge filtering of analyzer output.
- Runtime/production liveness for Swift on the server (no turnkey tool exists; Reaper covers iOS apps).\[8\]

## Details

### 1. State of the art: approaches and how large companies do it

**Static reachability over a graph (established).** Every large-scale system starts from a dependency graph and computes what is reachable from entry points.
- Google's Sensenmann (Google Testing Blog, April 2023) builds its graph from Blaze, Google's internal Bazel: binaries, libraries, tests and source files. Libraries that no binary links in are deletion candidates.\[9\]
- Meta's SCARF builds per-language dependency graphs with Glean at the symbol level and deletes unreachable subgraphs, including cycles. Moving from per-symbol checks to whole-graph analysis gave a nearly 50% increase in dead code removed in one large codebase.\[10\]
- Go's official `deadcode` tool (golang.org/x/tools, announced December 2023) applies Rapid Type Analysis from `main` and package initializers. It models interface dispatch and reflection conservatively, has a `-test` flag that includes test executables, and has a `-whylive` explanation mode.\[4\]\[11\]\[12\]

**Runtime / production usage data (established at big companies, harder for small teams).**
- Sensenmann logs every run of every internal binary to build a "liveness signal". Liveness spreads through the build graph, so everything a live binary depends on stays alive. Test runs deliberately do not count as liveness.\[9\]
- SCARF adds runtime usage from operational logs (API endpoints, script invocations, URI routes, async dispatch) on top of static analysis. Meta's engineering blog (October 2023) says SCARF has "automatically deleted more than 100 million lines of code in over 370,000 change requests" over five years, and the FSE 2023 paper adds over 46 million lines deleted in 2022 alone. The FSE 2023 paper reports 104 million lines and petabytes of data across 12.8 million assets.\[13\]
- On iOS, Emerge Tools' Reaper SDK, open-sourced by Sentry in November 2025, records which Swift/Objective-C types are used in production sessions. You subtract that set from the types in the binary. Duolingo's engineering blog reports the Reaper dashboard showed 2,684 unused classes out of 8,567 monitored, and that the team "removed over 10,000 lines of code, nearly 1% of our codebase".
- This matters because static tools cannot see code that is reachable but never executed. Duolingo found that Periphery-style static analysis "couldn't tell us which code was never used when the app was actually running".\[14\]

**Coverage-based approaches (established as a signal, not a decision rule).** Coverage tells you what tests exercise, not what production needs. Sensenmann notes that using coverage data to attribute tests to libraries "has not yet been explored".\[9\] Go's `deadcode -test` documentation frames the overlap differently: public functions that are dead even with tests included point to gaps in test coverage.\[4\]

**Feature-flag cleanup (established, with LLM successors emerging).**
- Uber's Piranha (ICSE-SEIP 2020) takes a stale flag name and its final treatment value, rewrites the AST to delete the dead branch, and assigns the diff to the flag owner. It supported Objective-C, Java and Swift. The ICSE-SEIP 2020 study (December 2017–May 2019) reports diffs generated for 1,381 flags (17% of all flags), with 65% of diffs landing without changes, over 85% compiling and passing tests, and about 71,000 lines deleted.
- PolyglotPiranha generalises this into a multi-language structural find-and-replace engine with cascading cleanup.\[15\]\[16\]
- Google's 2025 migration paper (arXiv 2501.06972) describes Gemini-driven experiment-flag cleanup that removes newly dead functions well but struggles with tests combining several flags.\[17\]
- DoorDash (InfoQ, September 2026) built a multi-agent LLM system for over 60,000 flags across 623 repositories because Piranha's syntactic rules did not cover its dependency-injection patterns. In a 50-flag evaluation, 45 produced usable PRs at an average of 13.8 minutes and $4.79 per cleanup.\[6\] **Frontier.**

**Build-graph dependency analysis (established).** Bazel-style strict deps and layering checks, Gradle's dependency-analysis plugin, include-what-you-use and Rust's cargo-shear all compare a target's declared dependencies with what its sources actually reference (Section 3).

**How the big companies run it.**
- Both Google and Meta send deletions as ordinary code reviews to owners. Sensenmann sends over 1,000 deletion changelists per week, has removed nearly 5% of all C++ at Google, and protects examples and non-logged programs with a blocklist. It reports reviewer feedback as "more frequently negative than positive".\[9\]
- SCARF lets engineers catch false positives in review, and those often reveal new kinds of dynamic usage. In some languages it auto-merges where confidence is high.\[18\] Its text-search (BigGrep) fallback deliberately accepts more false negatives to avoid false positives.\[10\]

**What transfers to a small team:**
- Treat "dead" as a conservative intersection across all configurations, not a single scan.
- Keep an explicit, reasoned blocklist (you already do).
- Make every deletion a small, revertible, owner-reviewed change.
- Prefer missing some dead code over deleting live code (SCARF's BigGrep principle).\[10\]
- Production telemetry is worth it only for code paths you cannot reason about statically. For a server-side Swift codebase this means cheap counters on suspicious entry points (routes, CLI subcommands, message handlers) for a fixed window before deletion, not a general tracing system. **Frontier for Swift; no turnkey tool.**

### 2. Swift-specific tools and compiler features

**Periphery (established, but in transition).**
- **Design:** Periphery builds the project to produce the index store, builds an in-memory graph of declarations and references, marks entry points, and reports what is unreachable. The README warns that the index store only contains files from compiled targets, and that Periphery uses the default (typically debug) configuration, so code in inactive `#if` branches is invisible.\[1\] For SwiftPM, all targets, including tests, are built automatically.\[1\]
- **Linux:** supported, but only for SwiftPM projects.\[1\] Issue #1124 notes the 3.7.4 GitHub release assets contained only a macOS binary, so Linux CI should build from source or use a container image.\[19\]
- **3.0 (Dec 2024):** Swift Testing support. Scans every file in the index store and removed `--targets`.\[20\]\[21\] 3.0.1 made a clean build unnecessary after deleting a file.\[22\]
- **3.1.0:** assign-only property analysis disabled under Swift 6.1 because of compiler bug swiftlang/swift#80394. `@_dynamicReplacement` members retained.\[23\]
- **3.2.0:** fixed unused-import false positives where the only referenced declaration is macro-generated. Fixed inconsistent results for files in multiple targets and for identical extensions in different modules. Fixed slow baseline filtering.\[24\]
- **3.3.0:** added `--retain-unused-imported-modules`. Excludes conditionally imported modules from unused-import detection "as they may provide symbols for code that was not compiled".\[20\]
- **3.7.0 (March 2026):** reports more unused code in a single scan rather than requiring repeated remove-and-rescan cycles. Fixed generic protocol extension handling in Swift 6.2.4.\[20\]\[25\]
- **3.8.0 (25 July 2026):** added `--retain-equatable-properties` and `--retain-hashable-properties`.\[25\]
- **Retention flags:** `--retain-public`, `--retain-assign-only-properties`, `--retain-assign-only-property-types`, `--retain-objc-accessible`, `--retain-unused-protocol-func-params`, `--no-retain-spi`, plus the dedicated Codable handling documented in the README.\[1\]
- **Commercial transition:** the repository was archived on 12 August 2026. Its README says Periphery "has transitioned from an open-source project to a commercial product". Issues moved to periphery-pro/issues.\[1\] The author's announcement says indie, hobby and open-source projects stay free, the MIT code remains forkable, and an open beta with no project-size limit is running. Periphery Pro claims up to 3× faster scans, an `agent-prompt` output format for AI coding agents, a VS Code extension, and a reusable GitHub workflow.\[7\] Treat these as vendor claims.

**Known false-positive classes in Periphery, each with an upstream source:**
- **Raw-value enums:** cases are always assumed used because they can be built dynamically.\[1\]
- **Protocol members:** reported unused when never called through an existential or generic, and a protocol that is only conformed to is reported as redundant. This is by design, not a bug.\[1\]
- **Unused imports:** detected only for scanned targets, because `@_exported` uses in other modules cannot be observed. Mixed Objective-C targets produce false positives.\[1\]\[26\]
- **Macros:** generated code produced unused-import false positives until 3.2.0 (issue #863).\[24\]\[27\]
- **Property wrappers:** with Xcode 27 / Swift 6.4, the indexer models `$foo` as a separate implicit declaration, so a SwiftUI `@State` property used only through `$selection` is reported unused (periphery-pro/issues #50).\[28\] This shows that each new compiler release can create new false-positive classes.

**SwiftLint analyzer rules (established, limited).** `unused_import` is an opt-in analyzer rule. It runs via `swiftlint analyze --compiler-log-path` against a full build log and has `require_explicit_imports`, `allowed_transitive_imports` and `always_keep_imports` options.\[29\] It takes SourceKit's *defining module* for each symbol and subtracts that from the import list.\[30\] That produces known false positives whenever a symbol is surfaced through a different module than the one that defines it:
- `import SwiftUI` for `ObservableObject` (#5167)\[30\]\[31\]
- `@_exported` re-exports (#5528)\[30\]
- `import OSLog` for `os.Logger`, reproduced on Swift 6.3.3 and still present in 0.65.1 (#6942)\[30\]

This is the same defining-module-versus-providing-module confusion that breaks naive import pruning on Linux.

**Compiler features (established):**
- **SE-0444 `MemberImportVisibility`** (implemented in Swift 6.1) makes members visible only from directly imported modules.\[32\]\[33\] That is exactly what catches a file "borrowing" an import from a sibling file.
- **SE-0409 access levels on imports** (`public`/`package`/`internal`/`private import`) with the `InternalImportsByDefault` upcoming feature (planned default in Swift 7).\[34\] In Swift 6 the compiler warns "public import of 'X' was not used in public declarations or inlinable code" (seen in swift-openapi-generator issue #968).\[35\] As of Swift 6.4 this warning belongs to the `UnusedImportAccess` diagnostic group. Swift 6.3.2 rejected `-Wwarning UnusedImportAccess` as an unknown group.\[36\]
- **SE-0443** gives diagnostic groups plus `-Werror <group>` / `-Wwarning <group>`.\[37\]\[38\] **SE-0480** brings warning control to SwiftPM manifests (e.g. `.treatWarning("EmbeddedRestrictions", as: .warning)` in Swift 6.3) and strips warning flags for remote dependencies.\[39\]\[40\] **SE-0522** adds a source-level `@diagnose(Group, as: error|warning|ignored, reason:)` attribute; a compiler engineer confirmed on the Swift Forums (28 August 2026) that `@diagnose(UnusedImportAccess, as: ignored)` works with the Swift 6.4 compiler.\[41\]\[42\]

**What is still missing.**
- The request for a general "warn on unused import" option (SR-2358, swiftlang/swift#44965) remains open.\[43\]
- SwiftPM's `--explicit-target-dependency-import-check=warn|error` detects *undeclared* target dependencies, not unused ones. It is not supported by the Swift Build backend (swift-package-manager #9620), and with prebuilt macros it reported a missing dependency that "randomly varies by build" (#8798).\[44\]\[45\]
- At package level, SwiftPM only warns "dependency 'X' is not used by any target". A third-party linter's design notes state plainly that "SwiftPM does not compare a target's imports with its dependencies".\[46\]\[47\]

**Linux Foundation layout (established, and the likely cause of your Linux break).**
- On Linux, `Foundation` comes from swift-corelibs-foundation. It re-exports `FoundationEssentials` and `FoundationInternationalization` from swift-foundation, while `FoundationNetworking` and `FoundationXML` are separate modules.\[48\]\[49\]
- Libraries increasingly write `#if canImport(FoundationEssentials) import FoundationEssentials #else import Foundation #endif` and scope Apple-only imports to platform guards. Swift-WebP's PR #67 verified the result on Linux by inspecting autolinked libraries.\[50\]\[51\]
- Different module boundaries on Linux mean "which import provides this symbol" has different answers per platform.
- Static linking adds its own failure modes: Swift 6.4 fails to link `FoundationEssentials` with `--static-swift-stdlib` on Linux (swift-foundation #2254).\[52\] So a "release" Linux build exercises a different link than a debug build.

### 3. Unused imports and dependencies in other ecosystems, and a cheap deterministic Swift approach

**Go (established):** unused imports are a compile error, so the problem never accumulates. `go mod tidy` removes modules nothing imports.\[53\] `deadcode` warns that its analysis "is valid only for a single GOOS/GOARCH/-tags configuration" and recommends running once per configuration and intersecting line-oriented results.\[4\] That is the single most transferable idea for your macOS/Linux problem.

**Rust (established):**
- rustc's built-in `unused_imports` lint handles in-file imports.
- `cargo-udeps` compiles the crate and reads the result. It needs nightly, misses doc-test usage, and is reported to have silently stopped detecting anything against newer cargo (GreptimeDB PR #9294 replaced it).\[3\]\[54\]
- `cargo-machete` is grep-based: very fast but imprecise, blind to macro-only use.\[54\]\[55\]
- `cargo-shear` analyses sources without compiling. It reports unused and misplaced dependencies and *unlinked source files*, supports `--fix`, `--deny-warnings` and JSON output, and takes per-crate ignore metadata with explanations.\[2\]\[3\]\[56\]
- The ecosystem trend is to run the static tool on every PR and keep build-based tools for a weekly backstop.\[2\] Your lint-time check matches this design.

**TypeScript (established):** Knip builds a whole-project module graph from entry points and reports unused files, exports and dependencies. It has a "production mode" that excludes tests so code reachable only from tests is reported, a `--strict` mode, `@public`/`@internal` tags to declare intentional exports, and `--fix`.\[57\]\[58\]\[59\]\[60\] ts-prune is in maintenance mode, and Knip is the recommended successor. Knip's production mode directly answers your "test-only seams" question: run the analysis twice, with and without tests, and treat "reachable only from tests" as its own category.

**Python:** Vulture reports every finding with a confidence percentage because the language is too dynamic for certainty.\[61\] That is a good model for ranking candidates.

**C/C++, JVM, Bazel:** include-what-you-use, the Gradle dependency-analysis plugin and Bazel's strict-deps/`unused_deps`/layering checks all apply "declared versus referenced" at file or target granularity. Their details were not re-verified in this research pass, but the principle matches the tools above.

**Cheap, deterministic option for Swift (recommended, partly frontier):**
- **Target dependencies:** a pure syntactic check, which is your current approach and the right one. Parse every source file of a target with swift-syntax, collect the `import` set across **all** `#if` branches, and compare it with `Package.swift` target dependencies (honouring `.when(platforms:)` conditions). Count `@_exported import` re-exports and `#externalMacro(module:)` references as uses. SwiftProjectLint's "Unused Target Dependency" rule follows this design and documents its own blind spot: excluded paths can produce false "unused" results.\[46\] Because it does not depend on a build, it is fast, platform-independent and deterministic.
- **Imports:** there is no cheap *and* fully correct per-file check, because "is this import needed" depends on overload resolution, extensions and re-exports. The practical deterministic recipe:
  - (a) Enable `MemberImportVisibility` everywhere, so every needed import is explicit in the file that needs it.
  - (b) Adopt `InternalImportsByDefault` / explicit access levels and promote the `UnusedImportAccess` group to an error with `-Werror UnusedImportAccess` (Swift 6.4+) to catch over-broad public imports.
  - (c) Treat import *removal* as a build-verified change that must pass on every platform × configuration in your matrix, never as a lint auto-fix.
  - (d) Keep a hard-coded "platform-sensitive modules" list (`Foundation`, `FoundationEssentials`, `FoundationInternationalization`, `FoundationNetworking`, `FoundationXML`, `Glibc`/`Musl`/`Darwin`, `os`/`OSLog`, `Dispatch`) that no automated pruner may touch without a Linux build.

### 4. Wiring it into a workflow

**Fast per-PR gates (established):** syntactic checks only, deterministic, seconds:
- Your target-dependency and unreferenced-file lint.
- `MemberImportVisibility` / `UnusedImportAccess` as compiler errors in the normal build.
- A Periphery "no *new* findings" check against a checked-in baseline, if your index build is reused from the PR's normal build.

Knip, cargo-shear and the Go tools are all designed to run this way.

**Slow scheduled scans (established):** nightly or weekly full Periphery scans on a **matrix**: macOS debug, macOS release, Linux debug, Linux release, in a pinned `swift:<version>` container. Take the **intersection** of "unused" results as deletion candidates and the **union** of "used" as the retention set, following the `deadcode` per-configuration guidance.\[4\] Anything unused on one platform but used on the other is not dead. It belongs in an `#if os(...)` block and should be flagged for a move, not deleted.

**Baselines and ratchets (established):** Periphery supports baselines, and 3.2.0 fixed slow baseline filtering for large result sets.\[24\] Write results to a checked-in baseline and fail only on new findings. Shrink the baseline deliberately. 3.8.0 also fixed `--write-results` so the file is written even when a scan finds nothing, which matters for deterministic CI artifacts.\[25\]

**Allowlists:**
- Use `// periphery:ignore` comment commands. Since 3.x they can sit inline, and ignored declarations also retain their references.\[20\]\[23\]
- Give each allowlist entry a reason, an owner and an expiry or review date, mirroring cargo-shear's "ignored entries with explanations".\[3\]
- Prefer category flags (`--retain-codable-properties`-style options, `--retain-equatable-properties`) over thousands of per-symbol ignores.

**Determinism (established causes, with concrete fixes):**
- Pin the toolchain *and* the scanner version. Periphery behaviour changes with compiler releases: Swift 6.1 assign-only bug, Swift 6.2.4 generic extension fix, Xcode 27 `$projectedValue` regression.
- Scan from a clean or freshly built index store in CI rather than an incremental developer store.
- Avoid features with documented non-determinism, such as `--explicit-target-dependency-import-check` with prebuilts.\[45\]
- Upgrade Periphery to at least 3.7.0, so one scan reports what used to need several remove-and-rescan cycles.\[25\]
- Sort and normalise output paths before diffing against the baseline.

### 5. LLM- and agent-based dead code removal: what the evidence says

**Detection accuracy.** DCE-LLM (NAACL 2025) reports over 94% F1 for unused and unreachable code, about 30 points above GPT-4o. However, it was measured on a constructed Python/Java dataset with injected dead code, not on real repository-scale Swift with protocols, macros and reflection.\[62\]\[63\]\[64\] Treat it as evidence that small fine-tuned models plus localisation beat raw prompting, not as evidence that LLMs can decide liveness. **Frontier.**

**What works in industry: LLM plus deterministic analysis plus build/test gates.**
- Google's code-migration paper (arXiv 2501.06972, ICSE-SEIP 2025) finds locations with deterministic AST/Kythe tooling. It validates every change by building and running tests, with model-based repair on failure, ranks several candidate prompts by validation results, and keeps all changes in human review.\[17\]
- In the int32→int64 migration, Google reports that "80% of the code modifications in the landed CLs were AI-authored" and that total migration time fell "by an estimated 50%" as reported by the engineers. Humans still often had to revert model edits that were wrong or unnecessary.
- In JUnit3→JUnit4, about 87% of AI-generated code was committed unchanged. Reviewer speed was the bottleneck.\[17\]
- A follow-up (arXiv 2504.09691) reports the LLM generated 74.45% of 595 submitted code changes across 39 migrations.\[65\]\[66\]
- Meta's SCARF uses no LLM at all for deciding deadness: graph plus runtime data plus review.\[18\]

**LLM filtering of analyzer false positives (best quantitative evidence).** The Fudan/Tencent study (Du et al., arXiv 2601.18844, ICSE 2026) measured 433 alarms (328 false positives, 105 true positives) from Tencent's BkCheck analyzer on advertising and marketing services code, using GPT-4o, Claude-Opus-4, Qwen-3-Coder and DeepSeek-R1.
- Basic prompting reached only 0.26–0.29 precision, and chain-of-thought was the weakest strategy.\[67\]
- An LLM agent combined with static path-constraint analysis (LLM4PFA) reached 0.83–0.93 precision and filtered out 94–98% of false positives. Recall of 0.75–0.88 stayed below the company's 90% target, so the filter still drops real issues.\[67\]
- Cost per alarm was $0.0011–$0.12, and LLM explanations cut human checking time from about 10 to about 3 minutes.\[67\]

This maps directly onto your skeptic: an LLM checking Periphery output is a precision filter that will sometimes "rescue" dead code (fine) and, more dangerously, sometimes confirm wrong deletions if it is not grounded in tools.

**Adversarial and multi-agent review (frontier, mixed evidence).**
- A 31-day, seven-target field study of a "refute-or-promote" protocol (Abhinav Agarwal, arXiv 2604.19049, April 2026, single author, no ablations) found that adversarial agents "killed roughly 79% of 171 candidates", and 83% of the 30 run under the final protocol. A critic from a *different model family* caught errors that same-family review missed in 3 of 19 approved fixes. Yet ten dedicated reviewer agents unanimously endorsed a non-existent Bleichenbacher padding oracle in OpenSSL's CMS module that one empirical test disproved.
- Work cited there reports that LLM judges lean strongly toward agreeing, and that a minority-veto rule outperformed a large ensemble. Other 2025–2026 papers find debate can *lower* accuracy, and that review in a fresh session beats same-session iteration.\[68\] These were not independently verified here.
- Uber's production uReview (August 2025) shows that a generator-plus-separate-grader pipeline with confidence thresholds and category suppression works at scale: 75% of comments marked useful, 65% addressed. Uber's lesson was that "single-shot prompting wasn't enough", but it published no single-model ablation.\[69\]
- **Bottom line:** adversarial review is effective at *rejecting* weak deletion candidates, which is your use case, because a skeptic that keeps code is cheap to be wrong. It is not trustworthy as the *final* safety argument. Recent research ("The Order Is the Guarantee", arXiv 2608.04611) proposes that execution must gate every deletion, with static-analysis candidates ordered first and learned proposals bounded behind them.\[5\]

**Common failure modes to design against:**
- Hallucinated "unused" claims based on text search that misses dynamic use (string keys, `Codable`, `NSClassFromString`, `@objc`, macro-generated references).
- Over-deletion that removes tests along with the code, so the suite still passes. Sensenmann deliberately excludes tests as liveness and pairs them with the library they test, so they are deleted *together*, consciously.\[9\]
- Unnecessary or wrong collateral edits, as in Google's migration reverts.\[17\]
- Correlated errors when every agent uses the same model and context.
- The newest vendor angle, Periphery Pro's `agent-prompt` format, keeps the decision in the static analyzer and uses the agent only to perform the edit.\[7\] That is the right split.

### 6. Proving a removal is safe beyond "it builds and tests pass"

The checks below combine established tooling with techniques we recommend. Most are standard compiler or binary tools, but using them as deletion gates is a design proposal for your project rather than documented industry practice.

- **Overload resolution and protocol defaults.** In Swift, deleting a more specific overload, or a concrete implementation that shadows a protocol-extension default, can leave the code compiling while calls silently bind to a different function: the generic overload, the extension default, or a different module's extension. "It builds" is therefore not evidence of equivalence for any deleted *function* that shares a base name with another declaration or satisfies a protocol requirement. Mitigations:
  - (a) Refuse automated deletion when another declaration with the same base name is visible in the same scope.
  - (b) For candidates touching protocol requirements or default implementations, compare the set of called symbols before and after. Index-store references or the demangled undefined/defined symbols in object files (`nm` + `swift demangle`) both work, and a change in *which* symbol a call site references is a red flag even when the build succeeds.
  - (c) Stage the removal: mark the declaration `@available(*, deprecated)` or `unavailable` for one cycle first. Any remaining caller then fails loudly at compile time instead of silently rebinding. Periphery already suppresses unused-parameter warnings in `@available(*, unavailable)` functions, so it supports this workflow.\[23\]
- **Public API.** For any target whose products are consumed outside the package, run `swift package diagnose-api-breaking-changes <baseline-ref>` (built on swift-api-digester) as a gate, or scan with `--retain-public`. Inside a closed monorepo, Periphery's redundant-public-accessibility results are the safer first step: make things internal, then delete.
- **Dynamic and reflective use.** Grep-based checks for string-addressed names (Codable `CodingKeys` and wire field names, `NSClassFromString`, `@objc`/`dynamic`, `Mirror`-based serializers, `@_dynamicReplacement`, plugin/registry lookups) should block deletion unless a human signs off. Periphery's defaults reflect the same idea: raw-value enum cases and `@_dynamicReplacement` members are retained and Objective-C accessibility can be retained wholesale. For `Codable` wire fields, a removal is a *schema* change. Verify it with round-trip tests against recorded payloads, not just compilation.
- **Other platforms and configurations.** Build *and test* the deletion on macOS and Linux, in both debug and release (`-c release`, which turns off `-enable-testing`, so `@testable` seams are not visible), plus any static-stdlib configuration you ship. Linux static linking of the Foundation family has its own bugs (swift-foundation #2254).\[52\]
- **Behaviour-preserving evidence (frontier, cheap to adopt):**
  - Diff the exported symbol table of release binaries before and after. A pure dead-code deletion should only remove symbols, never add or rename any.
  - Use mutation-style sanity checks: if deleting the candidate *and* reintroducing a trivial bug in its neighbour both leave tests green, your tests are not evidence either way.
- **Revertibility and owner review.** Sensenmann's and SCARF's safety ultimately rests on small, owner-approved, easily rolled-back changes.\[70\] Keep deletions small and grouped by area, and roll them back rather than patch forward when something breaks.

## Assessment of Your Current Setup

**Where it is already reasonable:**
- Periphery is the right declaration scanner.
- `MemberImportVisibility` is exactly the compiler feature designed for the sibling-file import problem.
- A fast syntactic lint for orphaned target dependencies and unreferenced files with a reasoned allowlist matches the cargo-shear/Knip design and is the correct substitute for a SwiftPM feature that does not exist.
- A skeptic agent that tries to prove each candidate is needed is consistent with the best evidence on adversarial review, used as a rejection filter.

**Where it falls short, and the likely root causes of each pain point:**
- **Codable false positives.** Properties used only through synthesized `Codable` conformances are read or written by compiler-generated code. In decode-only or encode-only types they can look assign-only or unused. Assign-only analysis has also been disabled or buggy around Swift 6.1.\[23\] Fix with Periphery's Codable retention options and a policy that wire-format fields are schema, not code.
- **Runtime-discovered parameterized tests.** Swift Testing `@Test(arguments:)` and its argument providers are referenced through macro expansion and discovered at runtime. Periphery added Swift Testing support only in 3.0 and fixed macro-generated reference cases through 3.2.0.\[20\]\[24\] Version drift in either Periphery or the compiler (as with the Swift 6.4 `$projectedValue` change) re-opens such gaps. Pin versions and retain test-target declarations by policy rather than per symbol.
- **Protocol requirements.** Periphery deliberately reports protocol members never called through the protocol, and protocols that are only conformed to, as redundant.\[1\] These are often *correct* reports that look like false positives. When the protocol is a public or extension point, use `--retain-public` or targeted ignores. When it is not, consider accepting the finding.
- **Test-only seams.** In debug builds `-enable-testing` and `@testable import` make internal seams look used by tests. In release they are not compiled into test-visible form. Following Knip's production mode, run a second scan *excluding test targets*.\[59\] Declarations used only by tests then form a separate, reviewable category instead of noise in the main report.
- **Slow and non-deterministic build-based checks.** Likely causes: incremental or stale index stores, older Periphery versions that needed clean builds after deletions or several rescans, inconsistencies for files in multiple targets and duplicate extensions (fixed in 3.2.0), and SwiftPM's own non-deterministic import check with prebuilts.\[22\]\[24\] Fix with pinned toolchain plus scanner, clean CI index builds, and moving per-PR gating to syntactic checks.
- **macOS-only scans.** The index store contains only compiled code, so everything behind `#if os(Linux)` / `canImport` branches that do not compile on macOS is invisible.\[1\] Code used only on Linux looks dead. Fix by scanning on Linux (SwiftPM projects are supported there) and intersecting the results.\[1\]
- **The Linux release build break from import pruning.** Most likely cause: pruning decided on macOS, where Apple's Foundation is a single umbrella module, removed an import that is the *providing* module on Linux. Examples are `FoundationNetworking` for `URLSession`, `FoundationXML`, a libc module, or `Foundation` itself where a file only appeared to need `FoundationEssentials`. A second possibility: the check ran in debug only, while release disables `-enable-testing`, changes optimisation and can take different `#if` branches. SwiftLint's defining-module attribution bug is the same mistake in a different tool.\[30\] Fix by never auto-pruning platform-sensitive modules and requiring a Linux release build for any import removal.

## Recommendations (prioritized for Swift 6, SwiftPM, ~1,100 files, 35 targets, macOS + Linux, small team)

1. **Make every import removal and deletion pass a 2×2 matrix** (macOS/Linux × debug/release, Linux in a pinned `swift:` container) before merge. This alone would have prevented the Linux release break. Add a hard-coded list of platform-sensitive modules that automation may never prune.
2. **Run Periphery on both platforms on a schedule and intersect the results.** Deletion candidates are findings unused on *both*. Findings unused on only one become "move under `#if`" tasks. Pin the Swift toolchain and Periphery version, and build the index from scratch in CI.
3. **Decide your Periphery future now.** Either stay on the archived MIT 3.8.0 and accept new compiler-version false positives (e.g. the Swift 6.4 `$projectedValue` issue), or join the free Periphery Pro open beta and re-evaluate licensing when it ends. Do not stay on a pre-3.7 version.
4. **Introduce a checked-in baseline and a ratchet.** The per-PR gate is "no new findings", with the baseline shrinking over time, plus allowlist entries carrying a reason, owner and review date. Replace per-symbol ignores with category retention flags (Codable, Equatable/Hashable, assign-only types) where the category is a policy.
5. **Split the scan into "production" and "with tests"**, Knip-style, so test-only seams and runtime-discovered test helpers form their own reviewed category instead of false positives.
6. **Turn on the compiler's import hygiene as errors:** `MemberImportVisibility` everywhere, explicit import access levels (prepare for `InternalImportsByDefault`), and `-Werror UnusedImportAccess` once you are on Swift 6.4, with `@diagnose(..., as: ignored, reason:)` for justified exceptions. Keep your syntactic target-dependency lint as the per-PR gate, and make it parse all `#if` branches and honour `@_exported` and `#externalMacro`.
7. **Restructure the agent workflow to put tools first:** Periphery (and your lint) propose, the skeptic agent tries to refute using tool-backed evidence (index references, grep for string/reflective use, cross-platform build results), and a mechanical gate decides. Use a different model family for the skeptic than for the proposer. Never let agent agreement substitute for the matrix build.
8. **Add cheap safety checks for risky classes:** block automated deletion of declarations that share a base name with another visible declaration or satisfy a protocol requirement, and stage those via `@available(*, deprecated/unavailable)` for one cycle. Run `swift package diagnose-api-breaking-changes` for externally consumed products, and diff release-binary symbol tables to confirm deletions only remove symbols.
9. **Optional, later:** for server entry points you cannot reason about statically, add lightweight usage counters for a fixed window before deleting, which is the small-team version of Sensenmann/SCARF liveness signals.

## Caveats

- Several 2026 sources are single-author arXiv preprints or vendor pages (Periphery Pro performance claims, DoorDash via InfoQ). Their numbers are reported, not independently replicated.
- Some figures (arXiv 2504.09691, LLM4PFA's abstract-level numbers, the debate counter-evidence) were seen only in abstracts or secondary citations.
- No published study measures LLM verifiers specifically on Swift dead-code detection. The transfer from static-analysis alarm triage is an inference.
- Bazel `unused_deps`, Gradle's dependency-analysis plugin and include-what-you-use are described at the level of general design and were not re-verified in this pass.
- Details of Swift 6.4 diagnostics (`UnusedImportAccess`, SE-0522) come from forum posts and issue trackers around August–October 2026 and may shift before or after final release documentation.

## Sources

1. [GitHub - peripheryapp/periphery: A tool to identify unused code in Swift projects.](https://github.com/peripheryapp/periphery)
2. [\[P2\] Evaluate a stable unused-dependency checker instead of nightly cargo-udeps on PRs · Issue #173 · zajca/pohunek](https://github.com/zajca/pohunek/issues/173)
3. [chore(deps): replace cargo-udeps with cargo-shear for unused dependency checks by sunng87 · Pull Request #9294 · GreptimeTeam/greptimedb](https://github.com/GreptimeTeam/greptimedb/pull/9294)
4. [deadcode command - golang.org/x/tools/cmd/deadcode - Go Packages](https://pkg.go.dev/golang.org/x/tools/cmd/deadcode)
5. [The Order Is the Guarantee: Verifier-Budgeted Code Deletion with Static-First Learned Proposals](https://arxiv.org/pdf/2608.04611)
6. [DoorDash Uses Multi Agent LLMs to Clean up 60,000 Feature Flags](https://www.infoq.com/news/2026/09/doordash-feature-flag-cleanup/)
7. [Periphery](https://periphery.pro/)
8. [Reaper - An open-source SDK for finding dead code](https://preview3.app.daily.dev/posts/reaper---an-open-source-sdk-for-finding-dead-code-r0y26gwxt)
9. [Sensenmann: Code Deletion at Scale](https://testing.googleblog.com/2023/04/sensenmann-code-deletion-at-scale.html)
10. [Automating dead code cleanup](https://engineering.fb.com/2023/10/24/data-infrastructure/automating-dead-code-cleanup/)
11. [Finding unreachable functions with deadcode - The Go Programming Language](https://go.dev/blog/deadcode)
12. [deadcode超解剖 - Speaker Deck](https://speakerdeck.com/kuro_kurorrr/deep-dive-into-deadcode)
13. [Dead Code Removal at Meta: Automatically Deleting Millions of Lines of Code and Petabytes of Deprecated Data (ESEC/FSE 2023 - Industry Papers) - ESEC/FSE 2023](https://2023.esec-fse.org/details/fse-2023-industry/12/Dead-Code-Removal-at-Meta-Automatically-Deleting-Millions-of-Lines-of-Code-and-Petab)
14. [emerge tools reaper](https://blog.duolingo.com/emerge-tools-reaper)
15. [GitHub - uber/piranha: A tool for refactoring code related to feature flag APIs · GitHub](https://github.com/uber/piranha)
16. [pypi.org](https://pypi.org/project/polyglot-piranha/0.3.5)
17. <https://arxiv.org/pdf/2501.06972v1>
18. [Software debloating papers](https://www.cesarsotovalero.net/software-debloating-papers)
19. [Please publish Linux binaries in GitHub releases · Issue #1124 · peripheryapp/periphery](https://github.com/peripheryapp/periphery/issues/1124)
20. [periphery/CHANGELOG.md at master · peripheryapp/periphery](https://github.com/peripheryapp/periphery/blob/master/CHANGELOG.md)
21. [3.0 Migration Guide · peripheryapp/periphery Wiki · GitHub](https://github.com/peripheryapp/periphery/wiki/3.0-Migration-Guide)
22. [Release 3.0.1 · peripheryapp/periphery](https://github.com/peripheryapp/periphery/releases/tag/3.0.1)
23. [Release 3.1.0 · peripheryapp/periphery](https://github.com/peripheryapp/periphery/releases/tag/3.1.0)
24. [Release 3.2.0 · peripheryapp/periphery](https://github.com/peripheryapp/periphery/releases/tag/3.2.0)
25. [Releases · peripheryapp/periphery](https://github.com/peripheryapp/periphery/releases)
26. [Periphery - Swift Package Registry](https://swiftpackageregistry.com/peripheryapp/periphery)
27. [False positive: Unused import & Swift Macros · Issue #863 · peripheryapp/periphery](https://github.com/peripheryapp/periphery/issues/863)
28. [Xcode 27: false-positive unused property for @State values referenced through \$projectedValue · Issue #50 · periphery-pro/issues](https://github.com/periphery-pro/issues/issues/50)
29. [unused\_import Reference](https://realm.github.io/SwiftLint/unused_import.html)
30. [unused\_import false positive for \`import OSLog\` when using \`os.Logger\` · Issue #6942 · realm/SwiftLint](https://github.com/realm/SwiftLint/issues/6942)
31. [unused\_import: false rule violation (importing SwiftUI to use ObservableObject and @Published in a macOS project) · Issue #5167 · realm/SwiftLint](https://github.com/realm/SwiftLint/issues/5167)
32. [github.com](https://github.com/apple/swift-argument-parser/pull/803)
33. [\[Pitch\] Fixing member import visibility - Pitches - Swift Forums](https://forums.swift.org/t/pitch-fixing-member-import-visibility/71432)
34. [\[Pitch\] Access-level on import statements - Pitches - Swift Forums](https://forums.swift.org/t/pitch-access-level-on-import-statements/66657)
35. ["Public import … was not used in public declarations" warnings in generated files since 1.13.0 · Issue #968 · apple/swift-openapi-generator](https://github.com/apple/swift-openapi-generator/issues/968)
36. [ci: bump Swift to 6.4.0 and keep UnusedImportAccess a warning by AllDmeat · Pull Request #37 · AllDmeat/ktalk](https://github.com/AllDmeat/ktalk/pull/37)
37. [Conflicting options '-Wwarning' and '-suppress-warnings' - Using Swift - Swift Forums](https://forums.swift.org/t/conflicting-options-wwarning-and-suppress-warnings/76714)
38. [github.com](https://github.com/swiftlang/swift/pull/85026/files)
39. [SwiftPM \`-warnings-as-errors\` and \`-suppress-warnings\` to dependency targets · Issue #10192 · swiftlang/swift-package-manager](https://github.com/swiftlang/swift-package-manager/issues/10192)
40. [Embedded Swift Improvements Coming in Swift 6.3](https://www.swift.org/blog/embedded-swift-improvements-coming-in-swift-6.3/)
41. [swift-evolution/proposals/0522-source-warning-control.md at main · swiftlang/swift-evolution](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0522-source-warning-control.md)
42. [Internal imports by default is very problematic for generated code](https://forums.swift.org/t/internal-imports-by-default-is-very-problematic-for-generated-code/82722?page=2)
43. [\[SR-2358\] \[QOI\] Warn on unused {{import}} statements · Issue #44965 · swiftlang/swift](https://github.com/swiftlang/swift/issues/44965)
44. [SwiftBuild does not support the \`--explicit-target-dependency-import-check\` command line flag · Issue #9620 · swiftlang/swift-package-manager](https://github.com/swiftlang/swift-package-manager/issues/9620)
45. [Enabling prebuilts for custom macros confuses \`--explicit-target-dependency-import-check=error\` · Issue #8798 · swiftlang/swift-package-manager](https://github.com/swiftlang/swift-package-manager/issues/8798)
46. [Check Package.swift dependencies against target imports by Joseph-Cursio · Pull Request #232 · Joseph-Cursio/SwiftProjectLint](https://github.com/Joseph-Cursio/SwiftProjectLint/pull/232)
47. [warning: dependency 'SwiftPM' is not used by any target · Issue #9 · americanexpress/xcprojectlint](https://github.com/americanexpress/xcprojectlint/issues/9)
48. [GitHub - swiftlang/swift-foundation: The Foundation project · GitHub](https://github.com/swiftlang/swift-foundation)
49. [GitHub - swiftlang/swift-corelibs-foundation: The Foundation Project, providing core utilities, internationalization, and OS independence · GitHub](https://github.com/swiftlang/swift-corelibs-foundation)
50. [Prefer FoundationEssentials for Linux builds by ainame · Pull Request #67 · ainame/Swift-WebP](https://github.com/ainame/Swift-WebP/pull/67)
51. [FoundationEssentials on Darwin? - Using Swift - Swift Forums](https://forums.swift.org/t/foundationessentials-on-darwin/74856)
52. [\[Linux\] Fail to link FoundationEssentials with Swift 6.4 and \`--static-swift-stdlib\` · Issue #2254 · swiftlang/swift-foundation](https://github.com/swiftlang/swift-foundation/issues/2254)
53. [Dead Code Analysis: The Best Detection Tools by Language (2026)](https://repowise.dev/blog/comparisons/best-dead-code-detection-tools)
54. [Unused Dependencies - Rust Project Primer](https://rustprojectprimer.com/checks/unused.html)
55. [cargo-machete, find unused dependencies quickly](https://bouvier.cc/tech/cargo-machete/)
56. [cargo-shear - crates.io: Rust Package Registry](https://crates.io/crates/cargo-shear)
57. [knip - npm](https://www.npmjs.com/package/knip/v/1.13.1)
58. [FAQ](https://knip.dev/reference/faq)
59. [Production Mode](https://knip.dev/features/production-mode)
60. [Unused dependencies](https://knip.dev/typescript/unused-dependencies)
61. [Finding API Endpoints, Tables and Flags Nobody Uses Takes Code and Traffic Together](https://apicoding.com/finding-api-endpoints-tables-and-flags-nobody-uses-takes-code-and-traffic-together)
62. [DCE-LLM: Dead Code Elimination with Large Language Models](https://aclanthology.org/2025.naacl-long.501.pdf)
63. [\[2506.11076\] DCE-LLM: Dead Code Elimination with Large Language Models](https://arxiv.org/abs/2506.11076)
64. [DCE-LLM: Dead Code Elimination with Large Language Models](https://arxiv.org/pdf/2506.11076)
65. [\[2504.09691\] Migrating Code At Scale With LLMs At Google](https://arxiv.org/abs/2504.09691)
66. [Migrating Code At Scale With LLMs At Google](https://getdx.com/research/migrating-code-at-scale-with-llms-at-google/)
67. [Reducing False Positives in Static Bug Detection with LLMs: An Empirical Study in Industry](https://arxiv.org/pdf/2601.18844)
68. <https://arxiv.org/pdf/2604.19049>
69. [uReview: Scalable, Trustworthy GenAI for Code Review at Uber](https://www.uber.com/us/en/blog/ureview/)
70. [Sensenmann: Code Deletion at Scale](https://news.ycombinator.com/item?id=35755841)
