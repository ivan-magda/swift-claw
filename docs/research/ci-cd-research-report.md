# Reference CI/CD Design for a Public Swift 6 Server-Side SwiftPM Package (swift-claw / `clawd`)

## TL;DR
- Keep the existing lint job and ADD a required `swift build` + `swift test` matrix on macOS (native, Swift 6.3.x) and Linux (official `swift:` container), both as required status checks under branch protection so an agent-authored PR that breaks a test cannot merge. The Linux job is the real GRDB/SQLite/FTS5 proof.
- **Do not** rely on the Swift Static Linux SDK (musl) to release `clawd`: GRDB v7 links the *system* libsqlite3 on Linux and vendors no SQLite amalgamation, and the musl SDK ships no SQLite — so build the Linux release binary *natively inside the official `swift:6.3-noble` container* against `libsqlite3-dev`. Ship a macOS-native binary + a native-Linux x86_64 (optionally arm64) binary, SHA256SUMS, and `actions/attest-build-provenance` attestations.
- Adopt the pragmatic hardening tier: Dependabot for `swift` + `github-actions`, third-party actions pinned to full commit SHAs, least-privilege `permissions:`, secret scanning + push protection, and build-provenance attestations. Add `zizmor` + `actionlint` as a cheap workflow-lint gate. Skip harden-runner/Scorecard/notarization as overkill for a solo maintainer.

## Key Findings

### The single most important decision: musl static cross-compile is the wrong default here
The task assumed a static-musl Linux binary cross-compiled from macOS as the release path. Research shows this is the wrong default for *this* package because of GRDB:
- GRDB v7's `Package.swift` declares its SQLite module as a **`.systemLibrary`** — verbatim: `.systemLibrary(name: "GRDBSQLite", providers: [.apt(["libsqlite3-dev"])])`. It does **not** compile a vendored SQLite C amalgamation. On Linux it links whatever `libsqlite3` the distro provides.
- The Swift Static Linux SDK ships **no SQLite**. Its SBOM (verified against `swift-6.2-RELEASE_static-linux-0.0.1` `sbom.spdx.json`) lists only `musl@1.2.5, musl-fts@1.2.7, libxml2@2.12.7, curl@8.7.1, boringssl@fips-20220613, zlib@1.3.1`. Swift.org's Static Linux SDK guide confirms system dependencies such as libsqlite are *not* statically linked and must be present on the target. So a musl cross-compile has nothing to link `sqlite3_*` against and fails at link time unless you supply your own musl-built static libsqlite3.
- Therefore the robust release path is a **native build in the official `swift:6.3-noble` container** with `apt-get install -y libsqlite3-dev`, producing a dynamically-linked glibc binary. Less "run anywhere" than a static musl binary, but it actually builds and matches how GRDB's own contributor-maintained Linux support is exercised.
- `SQLITE_ENABLE_FTS5` in GRDB's `Package.swift` is a **Swift** `.define`, not a C `.define` — it only unlocks GRDB's Swift FTS5 wrapper. Actual FTS5 must be present in the linked system SQLite. Debian/Ubuntu's `libsqlite3-dev` is built with FTS5, so `swift:*-noble` works; the Linux CI job is what proves it. GRDB v7 also explicitly sets `SQLITE_DISABLE_SNAPSHOT` on Linux, so WAL-snapshot optimizations differ from macOS.

### Toolchain selection (drift-prone — verified July 2026)
- **`swift-actions/setup-swift`** is the currently-maintained action; its v3 (beta) is built on **swiftly** and works on Ubuntu and macOS. **`SwiftyLab/setup-swift`** is also actively maintained (v1.13+, and can install SDKs like `static-linux;wasm;android` in one shot). Both are viable; for this project prefer pinning the toolchain via the official **`swift:` container on Linux** and **Xcode selection on macOS**, minimizing reliance on either third-party action.
- Swift cadence for context: 6.2 released September 15, 2025 (confirmed via the Swift.org "Swift 6.2 Released" post); 6.3 released 2026-03-24; 6.4 announced 2026-03-18. The project develops on Apple Swift 6.3.x.
- macOS runner minutes bill at a **10× multiplier** (per Depot.dev's calculator), at **$0.062/min** after the January 1 2026 rate cut (GitHub Docs "Actions runner pricing" lists macOS 3/4-core at $0.062), down from **$0.08/min** (per Clutch Engineering, Oct 2025). Crucially, **standard-runner usage on public repositories remains free** (confirmed via GitHub's "Pricing changes for GitHub Actions"), so the 10× cost only bites if the repo is private or uses larger runners.

### Attestations & release trust (verified)
- `actions/attest-build-provenance` still works, but GitHub now recommends `actions/attest@v4` for new implementations; both produce SLSA build provenance via Sigstore. Required permissions: `id-token: write`, `attestations: write`, `contents: read` (plus `contents: write` if the same job creates the Release).
- Downstream verification: `gh attestation verify <file> -R owner/repo` (or `--owner <org>`). Public repos use the Sigstore public-good instance; this meets SLSA Build L2.

### Dependabot swift ecosystem maturity (verified)
- The `swift` ecosystem is supported for a top-level `Package.swift` + committed `Package.resolved`. Two live gotchas: (1) use `https://` (not `scp`/`git@`) URLs in `Package.swift`/`Package.resolved` (dependabot-core #7709); (2) the repo URL in `Package.swift` must match `Package.resolved` exactly — a trailing `.git` mismatch silently excludes a dependency (dependabot-core #10296). Given these papercuts, Dependabot is adequate for this 8-dependency package; Renovate is a reasonable alternative if grouping/scheduling needs grow.

## Details

### A. CI build/test matrix

**A1 — macOS runners.** Use `macos-15` explicitly (not `macos-latest`, which drifts). Select the toolchain with `maxim-lobanov/setup-xcode` or `sudo xcode-select -s /Applications/Xcode_26.app` to pin Swift 6.3.x reproducibly rather than trusting the image default. To limit the 10× minute cost (only relevant if the repo is private), run macOS on `push`/PR to `main` and keep `timeout-minutes` tight (~20).

**A2 — Linux runners.** Prefer the **official `swift:6.3-noble` container on `ubuntu-latest`** over `setup-swift`, because the container guarantees the toolchain and lets you `apt-get install` system packages. For GRDB/SQLite/FTS5 you must install `libsqlite3-dev`; also install `ca-certificates` and `tzdata`. FTS5 is available because Ubuntu's libsqlite3 is compiled with it — the Linux job is the guarantee, exactly as GRDB intends (Linux support is contributor-maintained and not upstream-CI-tested for all configs).

```yaml
  linux:
    runs-on: ubuntu-latest
    container: swift:6.3-noble            # pin the toolchain via the image tag
    timeout-minutes: 20
    steps:
      - uses: actions/checkout@<sha>
      - name: Install system deps
        run: apt-get update && apt-get install -y libsqlite3-dev ca-certificates tzdata
      - run: swift build --build-tests
      - run: swift test --no-parallel      # honor .serialized loopback-HTTP suites; see A3
```

**A3 — Swift Testing in CI.** `swift test` runs `import Testing` suites natively on macOS and Linux under Swift 6.x (full "Automated" Linux support). For machine-readable output add `--xunit-output junit.xml`; note the SwiftPM quirk that the file is emitted as `junit-swift-testing.xml`, and that `--parallel` interacts with output generation (SwiftPM #8000). `.serialized` orders tests *within* a suite, but different suites still run in parallel, so loopback-HTTP suites in *different* suites can collide on ports; the safest CI setting is `swift test --no-parallel` (the suite is ~1s, so the parallelism loss is negligible), or bind distinct ephemeral ports. For inline PR annotations, feed the JUnit file to a pinned reporter (e.g. `dorny/test-reporter`), noting its `swift-xunit` support is marked experimental.

**A4 — Caching.** Cache `.build` keyed on `hashFiles('Package.resolved')` plus OS and Swift version, e.g. `key: ${{ runner.os }}-spm-${{ hashFiles('Package.resolved') }}`. Scope caches per-job (macOS and Linux must not share a key). On public repos, fork PRs get a read-only `GITHUB_TOKEN` and cannot write the base cache scope — good for cache-poisoning isolation, but fork PRs pay full cold-build cost. Include the Swift version in the key because the module cache is invalidated by toolchain changes (stale modules otherwise miscompile).

**A5 — Triggers & gating.** Run `pull_request` + `push` to `main`. **Keep lint path-filtered, but do NOT path-filter build/test** — a path-filtered *required* check that never runs stays "pending" forever and blocks merges (the classic pitfall). Use a `concurrency` group with `cancel-in-progress: true` to kill superseded runs. Under branch protection, mark the specific matrix job names (e.g. `test-macos`, `test-linux`) as required status checks.

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
```

**A6 — Matrix ergonomics.** Use separate macOS and Linux jobs (different setup) rather than one `os` matrix; if you use a matrix, set `fail-fast: false` so one platform failing still surfaces the other's result. `timeout-minutes: 20` per job. A Linux Swift-version matrix (6.2, 6.3) is nice-to-have but adds minutes; given the `.macOS(.v15)` floor and single-owner scope, testing Swift 6.3 on both platforms (plus optionally 6.2 on Linux) is right-sized.

### B. Release pipeline

**B7 — Linux binary (revised recommendation).** Build **natively in `swift:6.3-noble`** with `libsqlite3-dev` and `swift build -c release`, producing a glibc dynamically-linked binary — the robust path for a GRDB-dependent package. The "runs on any distro" property of a static binary would require building a musl-compatible static libsqlite3 yourself and injecting it (out of scope, maintenance-heavy; document as a future option). Ship x86_64 first; add arm64 via a second container job on an arm64 runner only if you have arm64 users. The Static Linux SDK bundle name+checksum (e.g. `swift-6.2-RELEASE_static-linux-0.0.1.artifactbundle.tar.gz` with checksum `d2225840…`) drifts every toolchain release and would need constant updating — another reason to avoid it here.

**B8 — macOS binary.** Build arch-specific (`arm64`) or a universal binary via `lipo -create`. For a solo maintainer without a paid Apple Developer account, **skip codesigning/notarization** and document the honest workaround: `xattr -d com.apple.quarantine ./clawd` (or download via `curl`/`scp`, which don't set the quarantine bit). Notarization needs a $99/yr Developer ID; note a standalone Mach-O binary **cannot be stapled** (only `.dmg`/`.pkg`/`.app` can), so cost/benefit is poor for a CLI daemon. If you later get a Developer ID, the lightest path is `codesign --options runtime --timestamp` → `ditto -c -k --keepParent` → `xcrun notarytool submit --wait`.

**B9 — Release automation.** Trigger on `push: tags: ['v*']`. Generate `SHA256SUMS` with `shasum -a 256`. Create the Release with `gh release create` (first-party, no pin) or `softprops/action-gh-release` (v2, pinned to SHA) which handles multi-asset globs and `generate_release_notes: true`. Mark `-rc`/`-beta` tags as prerelease (detect via `contains(github.ref_name, '-')`).

**B10 — Reproducibility & versioning.** Stamp the binary via a build flag or generated Swift file (e.g. inject `let version = "vX.Y.Z (<sha>)"` consumed by ArgumentParser's `.version`). Use SemVer `vMAJOR.MINOR.PATCH`. Full bit-for-bit reproducibility is not yet fully achievable in Swift; realistic steps today: pin the toolchain (container tag), commit `Package.resolved`, set `SOURCE_DATE_EPOCH`, and publish provenance attestations so consumers can verify origin even when bytes aren't reproducible.

### C. Supply-chain & security

**C11 — Dependabot config.** Cover both ecosystems; group to reduce PR noise (see workflow (c) below).

**C12 — Action pinning & hardening.** Pin every third-party action (`softprops/action-gh-release`, `maxim-lobanov/setup-xcode`, any setup-swift) to a full commit SHA; use Dependabot's `github-actions` ecosystem to bump them. Set least-privilege `permissions: contents: read` at the top level and elevate per-job only where needed. Worth adopting for a small public repo: **`actionlint`** (YAML/semantics errors) and **`zizmor`** (injection, unpinned actions, unsafe `pull_request_target`; its `unpinned-uses` rule since v1.20 enforces SHA-pinning) as a fast lint job. Skip **harden-runner** (EDR-style egress monitoring — valuable for orgs, overkill for a solo repo) and **OpenSSF Scorecard** (useful signal, maintenance overhead) unless you want the badge or gain contributors.

**C13 — Provenance attestations.** In the release job add `actions/attest-build-provenance` (or `actions/attest@v4`) after building each binary, with `subject-path` pointing at the binaries or `subject-checksums: SHA256SUMS`. Consumers verify with `gh attestation verify clawd-linux-x86_64 -R owner/swift-claw`. Stay at this pragmatic SLSA-L2 tier; cosign/SLSA generators (L3) are heavier and unnecessary now.

**C14 — Fork-PR safety.** Use `pull_request` (never `pull_request_target` for untrusted code) for CI. Fork PRs get a read-only `GITHUB_TOKEN`, no secrets, and no attestation identity — exactly what you want. Never run the release/attestation job on fork PRs (gate on `github.ref_type == 'tag'`). Fork-PR caches are isolated to the PR scope, preventing poisoning of `main`.

### D. Reference architectures (patterns only — clean-room)

**D15 — Well-run Swift server packages.** The dominant ecosystem pattern is **reusable workflows** from `swiftlang/github-workflows`: a `soundness.yml` (license headers, format, API-breakage via `swift package diagnose-api-breaking-changes`, unacceptable-language, broken-symlink checks) invoked via `uses: swiftlang/github-workflows/.github/workflows/soundness.yml@<ref>`, plus `swift_package_test.yml` testing a matrix across supported Swift versions (5.9–6.2, nightly, nightly-6.3) on Linux and Windows using official `swift:` and `swiftlang/swift:nightly-*` containers. apple/swift-nio, apple/swift-log, async-http-client, and swift-service-lifecycle consume these; GRDB.swift and Vapor run their own container matrices (`swift:*-jammy`/`*-noble`). Common shape: containerized Linux matrix, `fail-fast: false`, concurrency cancellation, `permissions: contents: read`, actions SHA-pinned. The reusable-workflow pattern is the biggest ergonomics lesson — a solo maintainer can adopt `soundness.yml` directly instead of re-inventing format/lint gating.

**D16 — Personal-AI-assistant / agent-daemon patterns.** Practices worth borrowing (not code): tag-triggered releases with attached binaries + checksums; container images for daemon distribution (deferred here); tight `permissions:` because the daemon stores private user data; **no secrets in CI test jobs** (tests use temp SQLite and scripted network doubles, so no live credentials should ever enter the runner); sandbox test side-effects (temp on-disk DBs, ephemeral ports, no writes outside the workspace). A daemon that runs untrusted-adjacent workloads should provide provenance so self-hosters can verify binaries, and must never expose its Telegram token or user data to CI — which this design enforces by keeping test jobs secret-free and release jobs fork-isolated.

## Annotated example workflows

### (a) CI: `.github/workflows/ci.yml`
```yaml
name: CI
on:
  push:
    branches: [main]
  pull_request:

permissions:
  contents: read                          # least privilege at top level

concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true                # kill superseded runs, save minutes

jobs:
  lint:                                    # existing job; path-filtering is OK here
    runs-on: ubuntu-latest
    container: swift:6.3.2-noble
    steps:
      - uses: actions/checkout@<sha>
      - run: swift format lint --strict --recursive Sources Tests Package.swift
      # SwiftLint via realm/swiftlint image or CLI

  test-linux:                              # REQUIRED check — never path-filtered
    runs-on: ubuntu-latest
    container: swift:6.3-noble
    timeout-minutes: 20
    steps:
      - uses: actions/checkout@<sha>
      - run: apt-get update && apt-get install -y libsqlite3-dev ca-certificates tzdata
      - uses: actions/cache@<sha>
        with:
          path: .build
          key: linux-spm-${{ hashFiles('Package.resolved') }}
      - run: swift build --build-tests
      - run: swift test --no-parallel      # honor loopback-HTTP .serialized suites

  test-macos:                              # REQUIRED check
    runs-on: macos-15
    timeout-minutes: 20                     # tight timeout — macOS is 10x cost if private
    steps:
      - uses: actions/checkout@<sha>
      - run: sudo xcode-select -s /Applications/Xcode_26.app   # pin Swift 6.3.x
      - uses: actions/cache@<sha>
        with:
          path: .build
          key: macos-spm-${{ hashFiles('Package.resolved') }}
      - run: swift build --build-tests
      - run: swift test --no-parallel

  workflow-lint:                           # cheap hardening gate
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@<sha>
      - uses: zizmorcore/zizmor-action@<sha>   # or step-security/zizmor-action
```

### (b) Release: `.github/workflows/release.yml`
```yaml
name: Release
on:
  push:
    tags: ['v*']

permissions:
  contents: write        # create the Release
  id-token: write        # Sigstore OIDC for attestations
  attestations: write    # write provenance

jobs:
  linux-binary:
    runs-on: ubuntu-latest
    container: swift:6.3-noble
    steps:
      - uses: actions/checkout@<sha>
      - run: apt-get update && apt-get install -y libsqlite3-dev ca-certificates
      - run: swift build -c release --product clawd
      - run: |
          cp .build/release/clawd clawd-linux-x86_64
          shasum -a 256 clawd-linux-x86_64 > clawd-linux-x86_64.sha256
      - uses: actions/attest-build-provenance@<sha>   # provenance for the binary
        with:
          subject-path: clawd-linux-x86_64
      - uses: actions/upload-artifact@<sha>
        with: { name: linux, path: 'clawd-linux-x86_64*' }

  macos-binary:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@<sha>
      - run: sudo xcode-select -s /Applications/Xcode_26.app
      - run: swift build -c release --product clawd
      - run: |
          cp .build/release/clawd clawd-macos-arm64
          shasum -a 256 clawd-macos-arm64 > clawd-macos-arm64.sha256
      - uses: actions/attest-build-provenance@<sha>
        with:
          subject-path: clawd-macos-arm64
      - uses: actions/upload-artifact@<sha>
        with: { name: macos, path: 'clawd-macos-arm64*' }

  publish:
    needs: [linux-binary, macos-binary]
    runs-on: ubuntu-latest
    steps:
      - uses: actions/download-artifact@<sha>
      - run: cat */*.sha256 > SHA256SUMS
      - uses: softprops/action-gh-release@<sha>      # pinned to SHA
        with:
          files: |
            */clawd-*
            SHA256SUMS
          generate_release_notes: true
          prerelease: ${{ contains(github.ref_name, '-') }}   # v1.2.0-rc1 => prerelease
```

### (c) `.github/dependabot.yml`
```yaml
version: 2
updates:
  - package-ecosystem: "swift"           # requires top-level Package.swift + Package.resolved
    directory: "/"
    schedule: { interval: "weekly" }
    groups:
      swift-deps:
        patterns: ["*"]                  # one grouped PR to reduce noise
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule: { interval: "weekly" }
    groups:
      actions:
        patterns: ["*"]
```

## Decision table

| Contested choice | Options | Tradeoff | Recommendation for swift-claw |
|---|---|---|---|
| Linux toolchain | Official `swift:` container vs `setup-swift` on ubuntu | Container pins toolchain + allows `apt`; setup-swift is lighter but adds a third-party action and no easy system-package install | **Container `swift:6.3-noble`** |
| Linux release binary | musl static cross-compile vs native container build | musl gives distro-portability but GRDB has no bundled SQLite and the musl SDK ships none → link failure; native builds reliably | **Native `swift:6.3-noble` + libsqlite3-dev** |
| macOS trust | Notarize (Developer ID) vs document `xattr` workaround | Notarization needs $99/yr and can't staple a bare Mach-O binary; workaround is free/honest | **Document `xattr -d com.apple.quarantine`** |
| Dependency bot | Dependabot vs Renovate | Dependabot is native but has swift papercuts (URL matching, scp URLs); Renovate is more flexible but another integration | **Dependabot** (swift + github-actions) |
| Release action | `gh release create` vs `softprops/action-gh-release` | gh is first-party/no pin; softprops handles multi-asset globs + notes but must be SHA-pinned | Either; **softprops@\<sha\>** for asset globbing |
| Hardening depth | actionlint+zizmor vs +harden-runner+Scorecard | First two are cheap high-value; latter two are org-grade overhead | **actionlint + zizmor only** |
| Swift selection action | swift-actions/setup-swift vs SwiftyLab/setup-swift | Both maintained; swift-actions v3 uses swiftly, SwiftyLab installs SDKs in one shot | Avoid on Linux (use container); on macOS use **maxim-lobanov/setup-xcode** |

## Swift-6 / SwiftPM / GRDB-SQLite pitfalls
- **GRDB has no vendored SQLite on SPM/Linux** — it links system `libsqlite3` (`.systemLibrary` + `apt libsqlite3-dev`). Install `libsqlite3-dev` in every Linux job or the build fails.
- **`SQLITE_ENABLE_FTS5` is a Swift define, not a C define** — FTS5 works only because Ubuntu's system SQLite has FTS5 compiled in; the Linux CI job verifies this. Don't assume it "just works" on an arbitrary distro.
- **GRDB v7 sets `SQLITE_DISABLE_SNAPSHOT` on Linux** — WAL snapshot optimizations are off on Linux; expect a behavioral difference from macOS.
- **musl static SDK ships no SQLite** — cross-compiling `clawd` with `--swift-sdk x86_64-swift-linux-musl` fails to link `sqlite3_*` unless you build a musl static libsqlite3 yourself.
- **musl `import` guards** — any code with `import Glibc` must also handle `#elseif canImport(Musl) import Musl`; a common failure when experimenting with the static SDK.
- **`--xunit-output` quirk** — with Swift Testing the file is emitted as `<name>-swift-testing.xml`; account for this when wiring PR annotations.
- **Loopback-HTTP suites** — `.serialized` orders tests *within* a suite, but different suites still run in parallel; use `swift test --no-parallel` in CI or bind ephemeral ports to avoid flaky port collisions.
- **Path-filtered required checks** — never path-filter build/test if they're required; a filtered-out required check stays "pending" and blocks all merges.
- **macOS-runner cost** — 10× multiplier ($0.062/min), but free on public repos; keep timeouts tight and avoid macOS on every draft push if the repo is private.
- **Dependabot swift URL matching** — use `https://` URLs and keep `Package.swift`/`Package.resolved` URLs byte-identical (watch trailing `.git`) or updates silently skip.
- **`macos-latest` / `swift:latest` drift** — pin `macos-15`, `swift:6.3-noble`, and the Xcode path explicitly.
- **GRDB v7 requirements** — Swift 6.1+ / Xcode 16.3+ (raised in v7.10.0); your Swift 6.3.x toolchain is comfortably above the floor.

## Recommendations (staged)
1. **Now (gate the tests):** Add `ci.yml` with `test-linux` + `test-macos`, make both required in branch protection, keep the lint job. This closes the "800 tests gate nothing" gap immediately. Benchmark: a broken PR now fails a required check and cannot merge.
2. **Next (supply chain):** Add `dependabot.yml` (both ecosystems), pin all actions to SHAs, set top-level `permissions: contents: read`, enable secret scanning + push protection, add the `zizmor`/`actionlint` job.
3. **Then (releases):** Add `release.yml` building macOS + native-Linux binaries with SHA256SUMS + provenance attestations. Document the macOS `xattr` step in the README. Benchmark: `gh attestation verify` succeeds on a downloaded asset.
4. **Later (if adoption grows):** Add arm64 Linux, a container image, a Homebrew tap, and auto-deploy — each slots in as an additional release job. Revisit musl static builds only if you invest in a musl SQLite build. Add harden-runner/Scorecard only if the repo gains contributors or org status.

Thresholds that change the plan: if the repo goes private, the 10× macOS cost becomes real → drop macOS to `main`-only or self-host. If you add a vector extension (sqlite-vec) requiring a custom SQLite amalgamation, the Linux link strategy changes (you'd vendor SQLite, which would then also make musl static builds feasible). If contributor count rises, add harden-runner + Scorecard.

## Caveats
- Version-sensitive / likely to drift: the Swift toolchain (6.3.x today), the Static Linux SDK URL+checksum (changes every release), `macos-15`/Xcode paths, action SHAs, and GitHub Actions pricing (rates cut Jan 1 2026). Re-verify before adopting.
- `actions/attest-build-provenance` is being superseded by `actions/attest@v4` for new work; both function today.
- GRDB Linux support is contributor-maintained and not upstream-CI-tested for all configs — your Linux job is the real proof, exactly as the project intends.
- The musl finding rests on GRDB v7's current `Package.swift` (systemLibrary, no vendored SQLite) and the Static Linux SDK SBOM (no SQLite); if GRDB later vendors a SQLite amalgamation, the musl path could become viable.
- Public-repo minutes are free, so the cost discussion is precautionary for a possible private phase or larger-runner use.

## Sources (primary, with currency)
- **Swift Static Linux SDK** — swift.org "Getting Started with the Static Linux SDK" (musl, static linking; system libs like libsqlite not statically linked); willhbr.net "The 6.2nd Stage of Swift on Linux" (Oct 2025, `swift sdk install` syntax + SBOM). Drift-prone: bundle URL/checksum change per release.
- **GRDB.swift v7** — groue/GRDB.swift `Package.swift` (master, mid-2026): `.systemLibrary("GRDBSQLite", providers: [.apt(["libsqlite3-dev"])])`, `SwiftSetting.define("SQLITE_ENABLE_FTS5")`, `SQLITE_DISABLE_SNAPSHOT` on Linux; `FTS5.swift`; Discussion #1821 (Linux port); Releases (v7.10.0 Linux focus, Swift 6.1/Xcode 16.3 bump).
- **GitHub Actions attestations** — actions/attest-build-provenance + actions/attest READMEs; GitHub Docs "Using artifact attestations to establish provenance for builds"; github.blog changelog (Feb 18 2025).
- **setup-swift actions** — swift-actions/setup-swift README (v3 on swiftly); SwiftyLab/setup-swift README + Swift Forums announcement (v1.13, SDK install).
- **Dependabot swift** — GitHub Docs "Dependabot supported ecosystems"; dependabot-core #7709 (scp URLs), #10296 (URL match); github.blog changelog (Swift advisories 2023, Xcode-project support Mar 2026).
- **Swift Testing** — swiftlang/swift-testing README; WWDC24 "Getting started with Swift Testing" (`.serialized`); SwiftPM #8000 (`--xunit-output` quirk); Swift Forums "How to serialize test suites?".
- **swiftlang/github-workflows** — repo README + `soundness.yml` (reusable soundness/`swift_package_test`); apple/swift-nio PR #3575 (version matrix).
- **Runner pricing** — GitHub Docs "Actions runner pricing" ($0.062 macOS); Depot.dev calculator (10× multiplier); GitHub "Pricing changes for GitHub Actions" (public repos free); Clutch Engineering/jeffverkoeyen.com (Oct 2025, prior $0.08).
- **macOS notarization** — Apple "Resolving common notarization issues"; scriptingosx.com "Notarize a command line tool with notarytool"; rsms gist (quarantine/`xattr`).
- **Release action** — softprops/action-gh-release README (v2/v3, multi-asset globs, prerelease).
- **Workflow security** — zizmor docs + mattsch.com (Mar 2026, `unpinned-uses`); step-security/harden-runner README; arXiv 2601.14455 (scanner comparison); Swift 6.2 release date via Swift.org "Swift 6.2 Released" (Sep 15 2025).