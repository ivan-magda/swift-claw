# Inc 5b Sandbox: Resolving the Open Questions — Base Image, Security Posture, Egress & Runtime

*Prepared 2026-07-11 as a focused second-pass design input for swift-claw Inc 5b ("Sandbox + code execution"), following the first research report (`inc5b-sandbox-code-execution-2026-07-11.md`) and a hands-on apple/container v1.1.0 spike. Inspiration only — clean-room; no code was copied. Method: multi-angle web research (6 search angles, 28 sources fetched, 117 claims extracted), with the top 30 claims each put through 3-vote adversarial verification: 24 confirmed, 6 refuted; findings synthesized by a separate Fable pass. Angles targeted: sandbox base image + supply chain, apple/container security posture, apple/container macOS 15 no-egress, swift-subprocess release + SF-0037, resource-exhaustion protection, controlled egress. This is a point-in-time research snapshot; its conclusions have already been folded into the Inc 5b design spec (see "Spec deltas applied").*

---

## TL;DR

The 24 verified claims resolve most of what the first report and the spike left open:

- **Base image decided: `cgr.dev/chainguard/python` (free tier, Wolfi-based), pinned by immutable digest.** wolfi-base currently scans CVE-free on the vendor's own dashboard; both wolfi-base and the python image ship three cosign-verifiable attestations (SLSA v1.0 provenance, apko config, SPDX SBOM); the python image runs nonroot by default. The one variant-level unknown: distroless production tags ship no shell, so the sh execution mode may need the `-dev` variant — a pin-time decision, with the nonroot default re-verified for whatever tag ships.
- **apple/container stays acceptable for the untrusted-code role.** All three published advisories — CVE-2026-28909 (HTTP-downgrade credential leak), GHSA-39g5-644c-qwcg (pf rule injection), GHSA-cq3j-qj2h-6rv3 (zip-slip) — are host-side registry/DNS/image-handling bugs, not guest escapes; the per-container full-VM isolation model is confirmed in primary docs. Doctor must assert a version floor that includes the 0.12.3 patch set — but the project's version stream is non-monotonic against the 1.1.0 spike build, so the exact 1.x floor must be resolved against release notes, not semver.
- **macOS 15 → hard floor at macOS 26, fail-closed.** No verified claim covers macOS 15 networking behavior (the one claim about it was refuted), and the spike validated `--network none` only on macOS 26.5.2 / container 1.1.0. Guessing wrong means silent full-internet egress for prompt-injected code, so doctor hard-fails execute_code on 15 rather than degrading.
- **swift-subprocess: host-side launcher only, pinned past PR #272.** It is a posix_spawn process spawner with zero isolation primitives. The issue #256 grandchild-holds-pipe hang is precisely clawd's timeout-kill path shape, so the pin must contain the 2026-05-27 fix (verified by commit ancestry, not version number); the 0.1 mandatory output byte limits give the stdout-flood cap for free.
- **Serialize executions (concurrency 1).** Virtualization.framework ballooning is partial — guest-freed pages are never returned to the host until VM teardown — so each VM holds its peak footprint for its whole life. There is no `--pids-limit` flag; a fork bomb is accepted as bounded by the VM memory cap plus disposal.
- **Controlled egress is foreclosed for 5b.** Container-to-host service access is a maintainer-acknowledged broken limitation (issue #346; the documented socat workaround reportedly does not work), which kills the host-side filtering-proxy design. `--network none` is the only shipped network mode; controlled egress is deferred until upstream lands native host-service access.

---

## Verified findings

### 1. Chainguard/Wolfi: CVE-free scan record plus three cosign-verifiable attestations, on two distinct trust roots

wolfi-base currently shows zero detected CVEs on Chainguard's own vulnerability dashboard — a live fetch on 2026-07-11 confirmed "This image is free of CVEs!" verbatim. This is a point-in-time vendor scan, not an independent audit; the number will fluctuate, and the durable value is the pipeline behind it: every wolfi-base and python build publishes three Sigstore/cosign-signed attestations — SLSA v1.0 provenance, an apko image-configuration attestation, and an SPDX SBOM — all retrievable and verifiable via cosign. The trust roots differ by tier and any verification step must target the right one: free-tier images are signed under a GitHub Actions OIDC identity (github.com/chainguard-images/images release.yaml, issuer `token.actions.githubusercontent.com`), while paid production images are signed under Chainguard's issuer.enforce.dev with service-account bindings. *(3-0 ×3; https://images.chainguard.dev/directory/image/wolfi-base/vulnerabilities, https://images.chainguard.dev/directory/image/wolfi-base/provenance, https://images.chainguard.dev/directory/image/python/provenance)*

### 2. Chainguard python: nonroot by default, glibc, distroless production tags ship no shell

The Chainguard python image runs as the nonroot user by default (root possible but recommended against) and is built on Wolfi (free tier) / Chainguard OS (paid), a glibc-based minimal "undistro" — no musl compatibility surprises for Python wheels. The distroless-style production tags ship no shell, package manager, or coreutils; the `:debug`/`-dev` variants deliberately add a shell back, which matters because execute_code's sh mode needs one. Medium confidence overall: the nonroot default and tiering are confirmed on Chainguard's own pages (3-0), the no-shell distroless property is blog-originated but corroborated against Docker and Google distroless docs (3-0), and the blog's ~15-40 MB size figure passed only 2-1 and is imprecise for bare wolfi-base (~5-7 MB compressed) — do not quote it. *(3-0 + 2-1; https://images.chainguard.dev/directory/image/python/overview, https://www.denis-iakimenko.com/blog/docker-base-image-types)*

### 3. apple/container: two 2026 advisories, both host-side, both patched in 0.12.3

CVE-2026-28909 / GHSA-m5rp-xcpf-r8m7 (Moderate, CVSS 6.9): insecure prefix matching in `isInternalHost()` (RequestScheme.swift) lets crafted hostnames like `localhost.evil.com`, `127.evil.com`, `192.168.evil.com`, `10.evil.com`, or `172.16-31.evil.com` be misclassified as internal, sending registry credentials over plaintext HTTP under the default `--scheme auto`. Affects <=0.12.1, patched in 0.12.3 — confirmed 3-0 from the GitHub advisory, corroborated by NVD. GHSA-39g5-644c-qwcg: `container system dns create` accepts unvalidated domain names, allowing pf rule injection; affects <=0.12.2, patched in 0.12.3. Both advisories were published 2026-04-30 and both are fixed in 0.12.3 — but this composite claim passed only **2-1**: the verifier flagged that the project's version stream appears non-monotonic relative to the 1.1.0 spike build, so whether the installed 1.x lineage contains these patches must be confirmed against release notes before hardcoding a doctor floor. Both bugs attack the operator's registry credentials and host pf rules via attacker-controlled hostnames — neither touches the guest boundary. *(3-0 + 2-1; https://github.com/apple/container/security, NVD CVE-2026-28909)*

### 4. apple/containerization: zip-slip in ArchiveReader (CVE-2026-20613, Low)

GHSA-cq3j-qj2h-6rv3 / CVE-2026-20613 (Low, CVSS 1.9, published 2026-01-22): `ArchiveReader.extractContents()` performs no pathname validation, allowing zip-slip path traversal on archive extraction; affects containerization <=0.20.1 / container <=0.7.1. Confirmed via the GitHub advisory plus NVD/OSV cross-references with matching versions and CVE ID. Another host-side image-handling bug, and another reason the doctor floor enforces a patched version. *(3-0; https://github.com/apple/containerization/security)*

### 5. apple/container: the full-VM isolation model Inc 5b relies on is untouched

Each container runs in its own lightweight per-container VM via the Containerization package — not a shared VM: the technical overview states verbatim that each container "has the isolation properties of a full VM," with a minimized in-guest utility/library surface, and this holds through the 1.0 GA. None of the three published advisories is a guest-to-host escape; the isolation property Inc 5b actually depends on — the VM boundary around prompt-injected code — has no published flaw. *(3-0; https://github.com/apple/container/blob/main/docs/technical-overview.md)*

### 6. swift-subprocess: a posix_spawn launcher with zero isolation primitives — and mandatory output limits since 0.1

swift-subprocess is purely a cross-platform process-spawning library: on Darwin it spawns via `posix_spawn()` (macOS-specific attribute access via `preSpawnProcessConfigurator`), exposes only Unix credential/process-group controls plus a configurable SIGTERM → timeout → SIGKILL teardown ladder, and has no network/filesystem isolation, sandbox, or CPU/memory/IO resource-limit primitives anywhere in the API — it cannot replace apple/container's VM isolation and is only suitable as the host-side launcher for the container CLI. Four merged 3-0 claims, verified against the README and the founding SF-0007 proposal. Separately, the 0.1 release removed default collected output buffers — callers must specify output type and byte limit (`.string(limit:)`/`.bytes(limit:)`), with errors thrown on breach — and removed `preSpawnProcessConfigurator` on Linux because no async-signal-safe implementation is possible. The mandatory limits bound memory when capturing subprocess output; the Linux removal is irrelevant to macOS-only 5b but matters for the Inc 6 Linux backend. *(3-0 ×6; https://github.com/swiftlang/swift-subprocess/blob/main/README.md, https://github.com/swiftlang/swift-foundation/blob/main/Proposals/0007-swift-subprocess.md, https://github.com/swiftlang/swift-subprocess/releases/tag/0.1)*

### 7. swift-subprocess: the 2026-05-27 hang fixes — issue #256 is exactly clawd's kill path

Two hang-class bugs were fixed on 2026-05-27. (1) Issue #256 / PR #272: Subprocess assumed killing a child would EOF inherited file descriptors, so pending stdin/stdout/stderr I/O was not cancelled — a grandchild holding the inherited pipe open hung cancellation indefinitely; fixed by cancelling AsyncIO on child exit across all platforms. This is directly the shape of clawd's timeout-kill path: `container run` spawns guest processes, so a pre-fix pin could hang the executor lane forever. (2) Issue #271: on kernels older than 5.4 (e.g. 4.14 Amazon Linux) the self-pipe/SIGCHLD fallback to `pidfd_open` discarded SIGCHLD and permanently hung the parent — irrelevant to 5b, relevant to the Inc 6 Linux backend. Both verified via the GitHub API: bodies, close timestamps, and the fix PR's mechanism match exactly. *(3-0 ×2; https://github.com/swiftlang/swift-subprocess/issues/256, https://github.com/swiftlang/swift-subprocess/pull/272, https://github.com/swiftlang/swift-subprocess/issues/271)*

### 8. Resource exhaustion: documented 1 GB / 4 CPU defaults, no pids-limit anywhere, partial ballooning

`container run` VMs default to 1 GB RAM and 4 CPUs, overridable via `--cpus`/`--memory` — quoted verbatim from how-to.md, which settles the first report's 1-2 refutation of the same figure (the spec still passes caps explicitly rather than trusting upstream defaults). There is no `--pids-limit` or equivalent flag anywhere in how-to.md or command-reference.md — only `--ulimit` and a read-only Pids metric in stats — so in-VM process-count exhaustion has no first-class CLI cap. Separately, Virtualization.framework implements only partial memory ballooning: pages freed by guest processes to the guest Linux OS are never relinquished to the host, so a VM holds its peak memory footprint until teardown. Host-side inspection (`container inspect`, per the spike), not guest-reported free memory, is the trustworthy signal, and disposal of the per-exec VM is the only real reclamation mechanism. *(3-0 ×3; https://github.com/apple/container/blob/main/docs/how-to.md, https://github.com/apple/container/blob/main/docs/command-reference.md, https://github.com/apple/container/blob/main/docs/technical-overview.md)*

### 9. Controlled egress: foreclosed upstream (issue #346)

Container-to-host service access is a maintainer-acknowledged known limitation of apple/container: not supported out of the box ("it's something we do want to get to"), the documented socat workaround was reported non-working by a user with a concrete repro, and the maintainers' native fix (PF redirect rules) was still an unimplemented design proposal in issue #346. This forecloses the host-side filtering-proxy route for allow-listed egress in Inc 5b: there is no reliable way for the VM to reach a proxy on the host. **2-1** vote — grounded in the issue thread via the GitHub API, not unanimous. *(2-1; https://github.com/apple/container/issues/346, https://github.com/apple/container/blob/main/docs/technical-overview.md#container-to-host-networking)*

---

## Decisions for Inc 5b

### 1. Base image

**Pin `cgr.dev/chainguard/python` (free/Starter tier, Wolfi-based) by immutable digest as the execute_code base image; verify the digest once at pin time with cosign against the free-tier trust root (issuer `token.actions.githubusercontent.com`, identity github.com/chainguard-images/images/.github/workflows/release.yaml) and archive the SLSA provenance + SPDX SBOM alongside the pin. If the sh execution mode requires a shell that the distroless production tag lacks, use the image's `-dev` variant (or wolfi-base with python added via apk in a locally built, digest-pinned derivative) and re-verify the nonroot default for that variant before shipping.**

The Chainguard/Wolfi family is the only candidate in evidence combining a currently CVE-free scan record, glibc (no musl compatibility surprises for Python wheels), nonroot-by-default execution, and three cosign-verifiable attestations (SLSA v1.0, apko config, SPDX SBOM) on the free tier. Digest pinning is already spike-validated on apple/container. The shell question is the one variant-level unknown, so it is called out rather than papered over. *Confidence: high.*

### 2. apple/container security posture

**Yes — apple/container remains safe enough for the Inc 5b role. All three known advisories (CVE-2026-28909 HTTP-downgrade credential leak, GHSA-39g5-644c-qwcg pf rule injection, GHSA-cq3j-qj2h-6rv3 zip-slip) are host-side registry/config/image-handling bugs, none is a guest-to-host escape, and the per-container full-VM isolation model is confirmed in primary docs. Mitigations to mandate: (1) doctor asserts the installed container version includes the 0.12.3 patch set (confirm the 1.x lineage contains it before hardcoding a floor); (2) pull only digest-pinned refs from cgr.dev over HTTPS — never a hostname that could trip the `--scheme auto` downgrade; (3) clawd must never invoke `container system dns create` or pass any LLM-influenced string into registry or DNS configuration.**

The advisories attack the operator's registry credentials and host pf rules via attacker-controlled hostnames — in clawd's design no untrusted party ever supplies a registry hostname or DNS domain, and the fixed image digest eliminates the remaining exposure. The isolation property Inc 5b actually depends on (the VM boundary around prompt-injected code) is untouched by any published advisory. *Confidence: high.*

### 3. macOS floor

**Floor at macOS 26: doctor must hard-fail execute_code enablement on macOS 15, not degrade-safe. Assert both the OS version and, at daemon start, that `container run --network none` semantics hold on the installed CLI version.**

None of the 24 verified claims covers macOS 15 networking behavior, and the spike validated `--network none` only on macOS 26.5.2 / container 1.1.0. The failure mode of guessing wrong is silent full-internet egress for prompt-injected code (omitting the flag attaches the default network), so uncertainty must fail closed. Degrade-safe support on 15 would require its own spike; nothing in evidence justifies spending it. *Confidence: medium.*

### 4. swift-subprocess

**Adopt swift-subprocess strictly as the host-side launcher for the container CLI (it provides zero isolation — this is explicit in the spec's threat model). Pin to the earliest tag that contains both the 0.1 API hardening and PR #272 (AsyncIO cancellation on child exit, merged 2026-05-27) — verify by tag/commit ancestry, not by version number alone. Use its now-mandatory output byte limits for stdout/stderr capture and its teardown ladder (SIGTERM → timeout → SIGKILL) for the CLI child. SF-0037's status was not established by this research (the claims verified SF-0007, the founding proposal); check the swift-foundation proposals index before finalizing the pin and treat it as a pin-time checklist item, not a blocker.**

The #256 grandchild-holds-pipe hang is precisely clawd's timeout-kill path shape (`container run` spawning guest processes), so a pre-fix pin could hang the executor lane forever. The 0.1 mandatory output limits give the stdout-flood cap for free. The Linux `preSpawnProcessConfigurator` removal and #271 kernel-fallback fix are irrelevant to the macOS-only 5b but matter for the Inc 6 Linux backend, so the same pin discipline carries forward. *Confidence: medium.*

### 5. Resource-exhaustion controls

**Yes, add controls beyond VM+timeout, all cheap: (1) pass `--cpus` and `--memory` explicitly on every run (defaults are 1 GB / 4 CPU but the spec should not depend on upstream defaults); (2) cap captured stdout/stderr bytes via swift-subprocess's mandatory output limits; (3) enforce the wall-clock timeout with SIGTERM → SIGKILL on the CLI, followed unconditionally by `container rm -f` of the execution container; (4) serialize executions (max concurrency 1) because partial ballooning means each VM holds peak memory until teardown; (5) accept the absence of a pids-limit — a fork bomb is contained by the VM's memory cap and ends with the VM's disposal. No new isolation machinery is warranted.**

The VM boundary already contains CPU/memory abuse; the residual risks in evidence are host-side (unbounded output capture, memory held by not-yet-torn-down VMs, orphaned containers after a hung kill) and each is closed by an existing flag or API feature. The missing pids-limit is a documented upstream gap with no CLI answer, and the disposable-VM model makes it a non-issue for a single-owner assistant. *Confidence: high.*

### 6. Egress

**Ship Inc 5b with exactly one network mode: `--network none`. Reject the other three options in the space: (a) default network = full internet for injected code, unacceptable; (b) allow-listed egress via a host-side filtering proxy — infeasible today because container-to-host access is a maintainer-acknowledged broken limitation (issue #346, socat workaround reported non-working); (c) custom vmnet/DNS configuration — touches the exact surface of GHSA-39g5-644c-qwcg and adds sudo requirements. Record in the spec that controlled egress is deferred until apple/container lands native host-service access (track #346), at which point a vetted-proxy design becomes the candidate.**

The option space collapses on the evidence: the only technically sound intermediate design (a host proxy the VM can reach) is blocked upstream, and the spike already established that anything short of an explicit `--network none` is full egress. A binary none/full choice with none as the sole shipped tier is both the safest and the only honest option for 5b. *Confidence: high.*

---

## Spec deltas applied

These seven deltas have already been folded into the Inc 5b design spec; this section records what changed and why, for traceability back to the evidence.

- **Base image (spec §7.1):** name `cgr.dev/chainguard/python` (free tier, Wolfi) pinned by immutable digest; record the digest in config; document the pin-time verification procedure (cosign verify-attestation against issuer `token.actions.githubusercontent.com` and identity github.com/chainguard-images/images/.github/workflows/release.yaml, archiving SLSA provenance + SPDX SBOM); note the image runs nonroot by default; flag the sh-mode shell question (distroless tag vs `-dev` variant) as a pin-time decision with re-verification of the default user.
- **Doctor assertions (macOS floor §7.2, container version floor §12.7):** (1) container CLI version includes the 0.12.3 patch set for CVE-2026-28909 and GHSA-39g5-644c-qwcg (resolve the exact 1.x floor against release notes before coding); (2) macOS version >= 26 — execute_code hard-fails on macOS 15 rather than degrading; (3) the pinned image digest resolves locally before enabling the tool.
- **Security posture note, new (§12.9):** all published apple/container advisories (CVE-2026-28909, GHSA-39g5-644c-qwcg, GHSA-cq3j-qj2h-6rv3) are host-side registry/DNS/image-extraction bugs, not guest escapes; mitigation posture = digest-pinned pulls from cgr.dev over HTTPS only, and an invariant that no LLM-influenced string ever reaches registry configuration or `container system dns` commands.
- **Run invocation (§9):** always pass explicit `--cpus` and `--memory` (document upstream defaults of 4 CPUs / 1 GB); state that no pids-limit flag exists and that fork bombs are bounded by the VM memory cap plus disposal; caps continue to be read host-side via `container inspect`.
- **Executor (§9, swift-subprocess pin §12.6):** swift-subprocess pinned to a tag verified to contain PR #272 (AsyncIO cancelled on child exit; guards the timeout-kill path against the issue #256 grandchild-pipe hang); stdout/stderr captured with explicit byte limits (API makes them mandatory since 0.1); teardown ladder SIGTERM → timeout → SIGKILL on the CLI followed by unconditional `container rm -f`.
- **Memory/concurrency (§9):** Virtualization.framework ballooning is partial — guest-freed pages are not returned to the host until VM teardown — so executions are serialized (concurrency 1) and the per-exec disposable VM is documented as the reclamation mechanism.
- **Egress (§2):** `--network none` is the only network mode in 5b; controlled/allow-listed egress is explicitly deferred, blocked on apple/container native host-service access (track upstream issue #346); custom vmnet/DNS configuration is ruled out as a widened attack surface.

---

## Refuted

What NOT to cite:

- "Latest release is Subprocess 0.5, dated May 30, 2026, requiring Swift 6.2 and Xcode 26" — **0-3**. Continues the first report's pattern: swift-subprocess version claims are systematically unreliable across sources. Pin by tag/commit ancestry and verify PR #272 is contained; never quote a version number from secondary material.
- "swift-subprocess has no documented sandboxing API — it just wraps posix_spawn/CreateProcessW with platform-specific escape hatches" — **1-2**. The no-isolation conclusion itself stands, but on the separately confirmed 3-0 claims (README + SF-0007); this particular framing failed verification and must not be the cited basis.
- "The maintainer's proposed #346 fix requires a privileged (sudo) helper writing /etc/resolver entries, HUPing mDNSResponder, and adding pf redirect rules" — **0-3**. The core limitation (no container-to-host access, broken socat workaround, unimplemented proposal) is confirmed at 2-1; the sudo-helper mechanics are not established and should not appear in the spec's rationale.
- "macOS 15 networking currently forces all containers onto one default network with no container-to-container isolation, and a network-helper/vmnet subnet mismatch can cause complete network isolation as a side effect" — **1-2**. This is the important negative for the floor decision: macOS 15 behavior remains *unestablished in either direction*, which is exactly why the decision fails closed at macOS 26 instead of relying on any claimed 15 behavior.
- "An early-2026 CVE scan found 7 high-severity CVEs in a distroless Python image vs 0 in Chainguard's and 2 in a pinned Wolfi image" — **0-3**. Comparative CVE-count marketing; the base-image decision rests on the primary-source dashboard and attestation pipeline, not vendor-adjacent scan anecdotes.
- "Standard Debian-based Docker Hub images average ~280 known CVEs versus Chainguard at zero or near-zero" — **0-3**. Same class of claim, same disposal.

## Caveats

This synthesis performed no new research; it operates only on the 24 pre-verified claims, so gaps in the claim set (macOS 15 behavior, SF-0037, exact release lineages) remain gaps. The wolfi-base zero-CVE finding is a point-in-time vendor dashboard state, not an audit, and will fluctuate — the durable value is the attestation/rebuild pipeline, not the number zero. The apple/container version stream appears non-monotonic across sources (advisories patched in "0.12.3" vs a "1.1.0" spike build), so the doctor version floor must be resolved against actual release notes rather than semver comparison. The ~15-40 MB Wolfi size figure is imprecise for bare wolfi-base (~5-7 MB compressed) and should not be quoted in the spec. Three claims survived on 2-1 votes and are graded medium accordingly: the advisory publication/patch metadata for GHSA-39g5-644c-qwcg, the issue #346 host-access limitation, and the Wolfi size/glibc packaging claim.

## Open items for build/pin time

1. Does the installed apple/container 1.x lineage (the spike ran 1.1.0) contain the 0.12.3 patches for CVE-2026-28909 and GHSA-39g5-644c-qwcg? The version ordering across sources is non-monotonic; confirm against the official release stream before hardcoding the doctor floor.
2. SF-0037 status and content: this research verified SF-0007 (the founding swift-subprocess proposal) but never established what SF-0037 changes or whether any tagged release implements it — check the swift-foundation proposals index at pin time.
3. Does the swift-subprocess 0.1 tag itself include PR #272 (merged 2026-05-27), or is a later tag required? Verify by commit ancestry.
4. Does the Chainguard python production (distroless) tag ship a shell adequate for the sh execution mode, or is the `-dev` variant / a wolfi-base-derived local image needed — and does that variant preserve the nonroot default user?
5. Chainguard's free tier is generally `:latest`-only: what is the digest-refresh cadence and CVE-response process for a pinned digest that ages (rescan on schedule vs re-pin on advisory)?
6. macOS 15 `--network none` semantics were never tested by any verified source; if degrade-safe support on 15 is ever wanted, it needs its own hands-on spike.
7. Long-term trust-root posture: is the free-tier GitHub Actions signing identity acceptable indefinitely, or should the pinned image be mirrored into a self-controlled registry to decouple from Chainguard's tag lifecycle?

## Sources

**Primary (15):** images.chainguard.dev/directory/image/wolfi-base (vulnerabilities, provenance), github.com/apple/container (repo, security, docs/how-to.md, docs/technical-overview.md, issues/345, issues/346), github.com/apple/containerization/security, github.com/swiftlang/swift-subprocess (repo, README.md, releases/tag/0.1, issues), github.com/swiftlang/swift-foundation Proposals/0007-swift-subprocess.md, forums.swift.org/t/review-sf-0037-subprocess-1-0/86004.

**Secondary (4):** images.chainguard.dev/directory/image/python (overview, provenance), forums.swift.org/t/second-review-sf-0037-subprocess-1-0/88199, github.com/bureado/awesome-agent-runtime-security.

**Blog (4):** safeguard.sh (distroless-vs-chainguard-vs-wolfi-base-images), denis-iakimenko.com (docker-base-image-types), emirb.github.io (microvm-2026), innoq.com (dev-sandbox-network).

**Forum (2):** github.com/apple/container/discussions/1170, github.com/apple/container/discussions/719.

**Fetched, no usable claims (3, unreliable):** edu.chainguard.dev (getting-started/python), arxiv.org/pdf/2606.08433, amux.io (ai-agent-sandboxing).
