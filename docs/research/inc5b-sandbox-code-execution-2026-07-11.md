# Sandboxing & Safe Code Execution for Always-On Agents: Verified Patterns for Inc 5b

*Prepared 2026-07-11 as design input for swift-claw Inc 5b ("Sandbox + code execution"). Inspiration only — clean-room; no code was copied. Method: multi-angle web research (8 search angles, 36 sources fetched, 184 claims extracted), with the top 32 claims each put through 3-vote adversarial verification: 21 confirmed, 11 refuted; findings synthesized by a separate model pass. Systems surveyed: apple/container, gVisor/runsc, Firecracker, Kata Containers, rootless Podman, swift-subprocess, plus the 2025–26 AI code-sandbox vendor landscape (Modal, E2B, Daytona).*

---

## TL;DR

clawd should execute untrusted, LLM-proposed code inside a disposable, hardware-isolated (or hardware-equivalent) sandbox created per execution and destroyed after it, never reused. The evidence resolves the two open backend decisions and hardens several §13 assumptions:

- **Linux backend decided: rootless Podman with gVisor `runsc` (Systrap platform) as the default runtime**, with a KVM-backed microVM runtime (Kata/Firecracker) as an opt-in "strong" profile where `/dev/kvm` exists. **Not** bare `runsc --rootless`: gVisor's own docs confirm that mode lacks `create`, lacks save/restore, and — critically — lacks Netstack, forcing host network access, which violates egress-denied-by-default. Podman supplies exactly the rootlesskit/newuidmap/`/etc/subuid` user-namespace plumbing gVisor requires for a real isolated network namespace.
- **macOS backend decided: apple/container** — one lightweight VM per container over Virtualization.framework, native `--cap-drop ALL`, `--init`, per-container `--cpus`/`--memory`. But its network isolation is confirmed gated on **macOS 26**, a direct conflict with the project's macOS 15 floor: on 15, all containers share the single default vmnet network, `--network` errors out, and Apple states no plan to fix 15-only issues. Either raise the execute_code floor to 26 or hard-degrade on 15 (networked runs refused, doctor warning).
- **Secure-by-default flag sets are asserted in code, never defaulted.** The claim that apple/container defaults to 1 GB / 4 CPUs was **refuted 1-2** — pass `--cpus`/`--memory` explicitly on every run. Cap adds are processed after drops (`--cap-drop ALL --cap-add ALL` grants everything), so the launcher must reject any `--cap-add` combined with `--cap-drop ALL`. Pin the CLI past the `--memory` hang fix (issue #1202, fixed in PR #1208, post-v0.9.0).
- **The never-reuse invariant gets independent validation from Firecracker**: its snapshot docs classify resuming execution from the same snapshot state more than once as insecure (RNG seeds, entropy pool, identifiers, crypto tokens). That categorically bans snapshot/clone-restored instances from any warm pool.
- **Egress stays denied by default** (`--network=none` on Podman; no network attachment on apple/container). Egress opt-in is one per-run parameter that both attaches a network and unconditionally sets `canExfiltrate=true`, forcing approval on tainted sessions. On macOS 15, where isolation is impossible, networked runs are refused outright rather than allowed-with-flag.
- **Ship without a warm pool.** Firecracker's spec targets ≤125 ms boot / ≤5 MiB VMM overhead and gVisor boots at container speed, so a Linux pool buys almost nothing; apple/container publishes no boot numbers at all, so the macOS decision must be measured (doctor boot-latency probe, per-run boot logging), not assumed.
- **swift-subprocess implements the deterministic-timeout contract natively**: a configurable teardown sequence (default SIGTERM → wait up to 5 s → SIGKILL, always concluding in kill, triggered on task cancellation). But every claim about its exact version status and about `closeAllUnknownFileDescriptors` existing was refuted in verification — the spec's Linux fd-hygiene assumption is unverified, and SF-0037 "Subprocess 1.0" is in second review through 2026-07-17.

---

## Verified findings

### 1. apple/container: one lightweight VM per container, minimal footprint, selective mounts

apple/container runs a lightweight VM for each container it creates — not process-level namespaces and not a shared VM — built on the Containerization Swift package over Virtualization.framework and vmnet. Each container "has the isolation properties of a full VM, using a minimal set of core utilities and dynamic libraries," and only explicitly mounted data enters the VM (no blanket host mount as in shared-VM designs). This matches the Inc 5b isolation unit (one execution = one disposable instance) and the no-host-bind-mount rule exactly. *(3-0 ×4; https://github.com/apple/container/blob/main/docs/technical-overview.md, https://github.com/apple/container/blob/main/docs/how-to.md)*

### 2. apple/container: full functionality requires macOS 26; macOS 15 is degraded and frozen

Apple's docs state that container "relies on the new features and enhancements present in macOS 26" and that network isolation is "available on macOS 26 and later." On macOS 15 there is no network isolation between containers (vmnet on 15 only isolates containers from the host's view of each other — all attach to the single default network), no `container network` commands (`--network` errors out), and fragile IP assignment; Apple states "there is no plan to address issues found with macOS 15 that cannot be reproduced on macOS 26." One of the two supporting claims was unanimous, the network-isolation gating itself passed on a **2-1** vote — grounded in the primary doc, but not unanimous. The important negative: the blanket claim that apple/container *requires* macOS 26 to run at all was **refuted 0-3** — it runs on 15, degraded. This is the sharpest tension with the Inc 5b macOS 15 platform floor. *(3-0 + 2-1; https://github.com/apple/container/blob/main/docs/technical-overview.md, https://github.com/apple/container/blob/main/docs/how-to.md)*

### 3. apple/container: the Inc 5b hardening set is natively supported — with a cap-ordering trap

`container run`/`create` support `--cap-add`/`--cap-drop` including `ALL` (the default is already a fixed restricted allowlist of ~14 capabilities — still far more than clawd wants), `--init` (in-container init that forwards signals and reaps processes), and per-container `-c/--cpus` and `-m/--memory` at 1 MiB granularity; how-to.md shows the explicit pattern `container run --cap-drop ALL --cap-add SETUID … alpine id`. Gotcha, confirmed: cap adds are processed **after** drops, so `--cap-drop ALL --cap-add ALL` grants everything — the no-cap-add invariant must be a code-level rule. Two important negatives: the claim that default resource caps are exactly 1 GB / 4 CPUs was **refuted 1-2** — pass caps explicitly, never rely on defaults; and a `--memory` hang bug existed in CLI v0.9.0 (issue #1202), fixed via PR #1208 — pin a CLI version newer than that fix. *(3-0 ×3 + 2-1 on the resource-cap flags; https://github.com/apple/container/blob/main/docs/command-reference.md, https://github.com/apple/container/blob/main/docs/how-to.md)*

### 4. apple/container: boot-time claims are qualitative only

The technical overview says per-VM containers "require less memory than full VMs, with boot times that are comparable to containers running in a shared VM" — and the verifier confirmed the doc contains no numeric figures anywhere. This finding rests on a **2-1** vote and is vendor self-characterization: sufficient to expect sub-seconds-to-few-seconds boots, insufficient to decide whether a warm pool is needed. Warm-pool sizing on macOS must be measured, not assumed. *(2-1; https://github.com/apple/container/blob/main/docs/technical-overview.md)*

### 5. gVisor: the Sentry passes no application syscall through to the host kernel

gVisor's Sentry is a full independent reimplementation of the syscall surface: "No system call is passed through directly to the host. Every supported call has an independent implementation in the Sentry" — architecturally stronger than ptrace/seccomp-style filters that merely authorize syscalls to execute on the host, because "all system calls are interpreted and handled by the Sentry itself." Raw CPU instruction execution carries zero gVisor overhead ("gVisor does not perform emulation or otherwise interfere with the raw execution of CPU instructions" — this specific claim passed **2-1**); the cost lives at syscall/I/O boundaries. Of its platforms, ptrace has "the highest structural costs by far" and is deprecated; Systrap is the recommended default and needs no hardware virtualization. Third-party benchmarks cited by verifiers put syscall-heavy I/O overhead at ~10-30% — acceptable for short LLM-proposed scripts, but note that figure is verifier-cited, not in the 3-vote-confirmed set. *(3-0 ×3 + 2-1; https://gvisor.dev/docs/architecture_guide/security/, https://gvisor.dev/docs/architecture_guide/performance/)*

### 6. gVisor rootless: bare `runsc --rootless` cannot be clawd's Linux launcher

The simple rootless mode does not support `create` (only `runsc do`-style flows), has no save/restore, and — critically — lacks Netstack support, "meaning you have to use the host network" instead of an isolated network namespace. Real network-namespace isolation under rootless gVisor requires caller-configured user-namespace tooling — rootlesskit as used by Docker/Podman — plus setuid helpers (newuidmap) and `/etc/subuid` multi-UID mappings, which enables Netstack via TAP devices and a usermode network stack. The rootless security model itself is sound (2-1 on that specific claim): user namespaces give the container apparent UID 0 and capabilities like CAP_SYS_ADMIN inside while it stays unprivileged on the host. Direct consequence: bare `runsc --rootless` violates clawd's egress-denied default; gVisor must be driven through Podman (or rootful runsc), never invoked standalone. *(3-0 ×2 + 2-1; https://gvisor.dev/docs/user_guide/rootless/)*

### 7. Firecracker: microVM-per-execution is affordable — and snapshot reuse is a documented hazard

Firecracker's specification enforces targets of ≤125 ms from the InstanceStart API call to the guest's `/sbin/init` (the 125 ms claim passed **2-1**) and ≤5 MiB VMM thread memory overhead — both measured at 1 vCPU / 128 MiB, tuned kernel, metal hosts. That proves VM-per-execution is viable on Linux where KVM exists. Separately and unanimously: the snapshot docs state "we consider resuming execution from the same state more than once insecure" unless uniqueness (RNG seeds, entropy pool, identifiers, crypto tokens) is guaranteed across restores. This independently validates the never-reuse-a-VM invariant and constrains warm-pool design: no restore-from-snapshot clones, ever. *(2-1 + 3-0 ×2; https://github.com/firecracker-microvm/firecracker/blob/main/SPECIFICATION.md, https://github.com/firecracker-microvm/firecracker/blob/main/docs/snapshotting/snapshot-support.md)*

### 8. swift-subprocess: the deterministic-timeout contract is implementable as specified

swift-subprocess natively implements a configurable graceful teardown sequence — default SIGTERM, wait up to 5 s, then SIGKILL; custom multi-step sequences via `PlatformOptions.teardownSequence` / `execution.teardown(using:)` — triggered automatically on task cancellation or manually, and "the teardown sequence always concludes by sending a kill signal." That maps 1:1 onto the ExecutionBackend stop-signal-then-SIGKILL requirement. The package is in Swift Foundation's SF-0037 "Subprocess 1.0" review (second review open through 2026-07-17); minimum Swift 6.1. Two cautions: every claim about the package's exact pre-1.0 version number was systematically **refuted** (0-3 / 1-2), and `closeAllUnknownFileDescriptors` — the fd-hygiene API the spec assumes on Linux — was **refuted / unverified** (0-3 and 1-2 across two sources). Its presence must be checked against the pinned release before the design relies on it. *(3-0 on teardown; https://swiftpackageindex.com/swiftlang/swift-subprocess, https://github.com/swiftlang/swift-subprocess)*

---

## Recommendations for Inc 5b

### 1. Linux backend

**Primary Linux backend: rootless Podman with gVisor runsc as the OCI runtime (`--runtime=runsc`, Systrap platform); an optional "strong" profile using a KVM-backed microVM runtime (Kata/Firecracker), selected via config when `/dev/kvm` is present. Do NOT drive runsc directly via `runsc --rootless`.**

Bare rootless runsc forces host networking and lacks `create` — incompatible with egress-denied-by-default — while the Podman path supplies exactly the rootlesskit/newuidmap/subuid userns plumbing gVisor's docs require for a real isolated network namespace. The Sentry's no-syscall-passthrough architecture is a materially stronger boundary than runc alone, Systrap needs no hardware virtualization (works in CI and on non-KVM hosts), and CPU-bound LLM code pays no interception cost. Firecracker's 125 ms / 5 MiB numbers prove microVM-per-exec is affordable where KVM exists, but raw Firecracker has no OCI/image story, so it belongs behind the same Podman/ExecutionBackend seam as an upgrade, not the default. This keeps one CLI contract (`podman run`) across both Linux profiles, mirroring the shell-out design used for apple/container. *Confidence: high.*

### 2. macOS backend

**Adopt apple/container, but treat macOS 26 as the effective floor for the execute_code feature — or, on macOS 15, hard-degrade: refuse networked runs entirely and surface a doctor warning. Pin a CLI version at or past the `--memory` hang fix (post-v0.9.0, PR #1208).**

The one-VM-per-container architecture matches the Inc 5b isolation unit exactly, and the CLI natively covers `--cap-drop ALL`, `--init`, `--cpus`/`--memory`, and selective mounts. But Apple's own docs say full functionality requires macOS 26, network isolation is unavailable on 15 (all containers share the default vmnet network, `--network` errors, IP assignment is fragile), and Apple will not fix 15-only issues. Since egress control is a load-bearing security property (`canExfiltrate`), shipping the sandbox on an OS where network attachment cannot be isolated is not secure-by-default; gating the feature is cheaper and safer than compensating controls. *Confidence: high.*

### 3. Hardening flag sets

**Secure-by-default launcher flag sets, asserted (not defaulted) on every run. Enforce in code that no `--cap-add` can ever be combined with `--cap-drop ALL`.**

apple/container — no `--volume` host mounts (stage inputs into the scratch dir baked into the image mount), no network attachment unless egress is opted in:

```sh
container run --rm --cap-drop ALL --init --cpus 4 --memory 1G
```

Podman/runsc (rootless):

```sh
podman run --rm --runtime=runsc --network=none --cap-drop=ALL \
  --security-opt=no-new-privileges --read-only --tmpfs /tmp \
  --init --memory=1g --cpus=4 --userns=auto
```

Every flag on the apple/container side is confirmed present in the command reference, with ALL-style drop explicitly documented; the confirmed cap-ordering gotcha (adds processed after drops) makes the no-cap-add invariant a code-level rule, not a convention. The claim that apple/container defaults to 1 GB / 4 CPUs was refuted, so caps must always be passed explicitly. `--read-only`/`no-new-privileges`/seccomp knobs were not confirmed for apple/container — the VM boundary substitutes there — but they are standard, cheap hardening on the Podman path, where the boundary is a userspace kernel (the Sentry) rather than a separate VM. *Confidence: high.*

### 4. Warm pool

**Ship without a warm pool first; make the pool an optional optimization behind the ExecutionBackend seam. If added, the pool holds only freshly booted, never-executed instances (pre-pulled image + pre-created VM/container) — NEVER snapshot-restored or cloned instances. Add a boot-latency probe to `doctor` and log per-run boot time to decide empirically whether the pool is worth it on macOS.**

Confirmed numbers say Linux microVMs boot in ≤125 ms and gVisor containers boot at container speed — a warm pool buys almost nothing there. apple/container claims boot "comparable to containers in a shared VM" but publishes no numbers, so the macOS decision must be measured. Firecracker's snapshot doc confirms that resuming identical state more than once is insecure (RNG seeds, entropy, tokens), which independently validates the never-reuse invariant and categorically rules out clone-based pooling as a latency shortcut. *Confidence: high.*

### 5. Supply chain + doctor sandbox self-check

**Pin the sandbox base image by immutable digest (`image@sha256:…`) in config, and extend `doctor` with a sandbox self-check: boot a canary container and assert from inside it that (1) the effective capability set is empty (`--cap-drop ALL` took effect, not just the default allowlist), (2) no network interface is up when egress is off, (3) memory/CPU caps match config, (4) PID 1 is the init reaper, (5) the scratch mount is the only writable path. Fail closed: execute_code stays disabled until doctor passes.**

apple/container's confirmed default is a ~14-cap restricted allowlist — still far more than clawd wants — so doctor must verify the empty effective capset rather than trusting defaults. The refuted default-caps claim and the fixed-then-shipped `--memory` hang bug show this toolchain is young and version-sensitive; asserting observed behavior per boot converts vendor-doc trust into runtime evidence, consistent with the project's enforce-policy-in-code rule. *Confidence: high.*

### 6. Egress

**Default = no network attachment: `--network=none` on Podman/runsc; on apple/container (macOS 26) run with no network / an isolated per-run network. Egress opt-in is an explicit per-run parameter that (a) attaches a network and (b) unconditionally sets `canExfiltrate=true` on the ExecutionRequest, forcing approval when the session is tainted. On macOS 15, where network isolation is confirmed impossible, networked runs are refused outright rather than allowed-with-flag.**

The macOS 26 gating of network isolation is confirmed 3-0/2-1 from Apple's own docs; on 15 any networked container shares the single default vmnet network, so "opted-in egress" there cannot be scoped and would silently widen the boundary. On Linux, bare rootless runsc's confirmed host-network requirement is precisely why the Podman path was chosen — `--network=none` under Podman gives a genuinely absent network namespace. Wiring `canExfiltrate` to the same parameter that attaches the network keeps the policy in code, with no way to get egress without the taint bit. *Confidence: high.*

### 7. swift-subprocess

**Use swift-subprocess's teardown API as the single timeout mechanism: on deadline or cancellation, run a custom teardown sequence (stop-signal, bounded wait, guaranteed SIGKILL) against the backend CLI process, paired with the CLI's own stop/kill of the container/VM. Pin a tagged release (track SF-0037 1.0 acceptance; review closes 2026-07-17) and verify the Linux fd-hygiene API before the design references it.**

The teardown sequence (SIGTERM, wait, SIGKILL, always ends in kill, cancellation-triggered) is confirmed verbatim from the repo docs and maps 1:1 onto the spec's deterministic stop-signal-then-SIGKILL requirement. However, every claim about the package's exact version status and about `closeAllUnknownFileDescriptors` was refuted in verification — so the spec's Linux fd assumption is currently unverified and must be confirmed against the pinned release (or replaced with an explicit close-range approach) before Inc 5b code depends on it. *Confidence: high.*

---

## Design deltas vs ARCHITECTURE.md §13

Concrete changes the normative spec should absorb:

- **Platform-floor conflict.** The project floor is macOS 15, but apple/container's network isolation and full functionality are confirmed to require macOS 26, and Apple will not fix 15-only issues. The spec should either raise the floor for the execute_code feature to macOS 26 or codify a hard degradation on 15 (networked runs refused, doctor warning).
- **Reword the isolation invariant** from "one disposable VM" to "one disposable, never-reused isolation instance": the recommended Linux default (Podman + gVisor runsc) is a userspace-kernel sandbox per execution, not a VM. If the spec means VM literally, Linux is forced onto KVM-only microVM runtimes, excluding non-KVM hosts and most CI.
- **Ban snapshot/clone-restored instances** in the warm-pool clause ("amortize only the boot of a fresh instance"), citing Firecracker's confirmed position that resuming identical state more than once is insecure — otherwise a future optimization could reintroduce it.
- **`closeAllUnknownFileDescriptors` on Linux is unverified** — all claims about it were refuted in adversarial verification. Either confirm it exists in the pinned swift-subprocess release or specify an alternative (close_range in the spawned shim).
- **The "do NOT embed pre-1.0 libraries" framing around swift-subprocess may be stale**: SF-0037 "Subprocess 1.0" is in its second review (through 2026-07-17). Restate the rule as "pin a tagged release; re-evaluate embedding after 1.0 lands" rather than a permanent shell-out assumption for the process-spawning layer itself (the container engines remain shell-out).
- **Never trust apple/container defaults for resource caps**: the claim that defaults are 1 GB / 4 CPU was refuted. `--cpus` and `--memory` must be passed explicitly on every invocation, and the launcher must reject any configuration that combines `--cap-drop ALL` with a `--cap-add` (confirmed ordering: adds win).

---

## Refuted

What NOT to cite:

- "apple/container requires macOS 26 to run at all" — **0-3**. It runs on macOS 15, degraded; the conflict is about *network isolation and full functionality*, not launchability. Overstating this would misframe the floor decision.
- "apple/container's default resource caps are 1 GB RAM / 4 CPUs" — **1-2**. Matters directly: the launcher must pass `--cpus`/`--memory` explicitly on every run; defaults are unknown and untrusted.
- "gVisor's Sentry itself uses only a minimal restricted subset of host syscalls (fd dup/close, sync, timers, signals)" — **0-3**. The confirmed security claim is no *application* syscall passthrough; do not additionally claim a minimized Sentry-side host surface.
- swift-subprocess exact-version claims ("currently 0.4.x", "latest release 0.5", "accepted at 0.1", "initial release 0.1") — **systematically refuted, 0-3 ×4 / 1-2 ×1** across the repo, README, SF-0037 proposal, Swift Package Index, and the 0.1 release tag. The package's release status as of the evidence is unknown; pin and verify, don't quote a version.
- "`closeAllUnknownFileDescriptors` exists on Linux / emulates POSIX_SPAWN_CLOEXEC_DEFAULT" — **0-3 and 1-2** (two independent source claims). The spec's Linux fd-hygiene assumption rests on nothing verified.
- The README-sourced variant of the graceful-teardown claim — **1-2**. The teardown fact itself stands on the separate 3-0 confirmation from the repo/Swift Package Index docs; only this duplicate sourcing failed.

## Caveats

Boot-latency evidence is asymmetric: Firecracker's ≤125 ms / ≤5 MiB figures are spec-enforced targets measured under idealized conditions (1 vCPU, 128 MiB, tuned kernel, metal hosts with SMT off) — a 1 GB / 4 CPU guest with a real rootfs will be slower and heavier; apple/container publishes no numbers at all, so all macOS pooling decisions rest on local measurement. Nearly all apple/container findings come from Apple's own repo docs (single-vendor primary source, young project with known just-fixed bugs). Kata Containers — one leg of the original Linux decision — has zero confirmed claims here, so the Podman+runsc-vs-Kata comparison is grounded on gVisor/Firecracker evidence only. gVisor syscall-overhead figures (~10-30% on I/O-heavy work) came from verifier-cited third-party benchmarks, not the 3-vote-confirmed set. swift-subprocess version/API-surface claims were systematically refuted, so its exact release status and the presence of `closeAllUnknownFileDescriptors` as of 2026-07 are unknown; the SF-0037 review outcome (closing 2026-07-17) postdates this report's evidence. Several findings rest on 2-1 votes (apple/container boot comparability, the macOS-26 network-isolation gating, Firecracker's 125 ms boot target) — high verifier confidence, not unanimous.

## Open questions

1. What is the measured cold-boot latency of apple/container on the target Mac hardware for the actual clawd base image at 1 GB / 4 CPU — and does it justify a warm pool at all?
2. Can apple/container start a container with no network attachment whatsoever (a true `--network=none` equivalent) on macOS 26 — and what happens on macOS 15: is the default vmnet attachment avoidable?
3. Does the pinned swift-subprocess release actually expose `closeAllUnknownFileDescriptors` (or an equivalent) on Linux, and did SF-0037 land 1.0 with that API intact?
4. Which gVisor platform should clawd's doctor select/verify on target Linux hosts (Systrap vs KVM), and does CI without nested virtualization constrain the acceptance-test matrix for the "strong" microVM profile?
5. Does apple/container offer read-only rootfs, seccomp, or rootless-daemon options (none were covered by confirmed claims) — and if not, is the per-container VM boundary alone accepted as the compensating control in the spec?

## Sources

**Primary (20):** github.com/apple/container (repo, docs/technical-overview.md, docs/command-reference.md, docs/how-to.md, issues), gvisor.dev (architecture_guide/security, architecture_guide/performance, architecture_guide/intro, user_guide/rootless, user_guide/networking), github.com/swiftlang/swift-subprocess (repo, README.md, releases/tag/0.1), github.com/swiftlang/swift-foundation Proposals/0007-swift-subprocess.md, swiftpackageindex.com/swiftlang/swift-subprocess, github.com/firecracker-microvm/firecracker (SPECIFICATION.md, docs/snapshotting/snapshot-support.md), ar5iv.labs.arxiv.org/html/2102.12892, docs.oracle.com (Podman pasta networking), github.com/shayonj/gvisord docs/security.md.

**Secondary (2):** en.wikipedia.org/wiki/Apple_container, swiftpackageregistry.com/swiftlang/swift-subprocess.

**Blog (9):** northflank.com (kata-containers-vs-firecracker-vs-gvisor, kata-containers-vs-gvisor, what-is-aws-firecracker), edera.dev (kata-vs-firecracker-vs-gvisor isolation), anil.recoil.org/notes/apple-containerisation, modal.com/blog/top-code-agent-sandbox-products, addozhang.medium.com (AI agent code-execution sandboxes), sanj.dev (podman pasta vs slirp4netns), dev.to/trknhr (apple/container v1.0.0).

**Forum (2):** github.com/apple/container/discussions/719, github.com/apple/containerization/issues/737.

**Fetched, no usable claims (3, unreliable):** thenewstack.io (Apple containers vs Docker), johal.in (gVisor/Kata benchmark), theswift.dev (swift-subprocess automation post).
