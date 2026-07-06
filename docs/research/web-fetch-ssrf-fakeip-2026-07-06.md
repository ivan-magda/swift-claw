# web_fetch SSRF guard vs fake-IP VPN/proxy — root cause & safe auto-detection (2026-07-06)

**Diagnosis + fix-design layer.** Why `web_fetch` refuses legitimate public URLs when the owner runs a system VPN/proxy in **fake-IP** DNS mode, whether the fake IP is stable, and whether swift-claw can safely detect and allow the fake-IP pool **automatically** without hand-configured exemptions. Grounds the decision behind [issue #26](https://github.com/ivan-magda/swift-claw/issues/26).

> **Verification key.** Every material claim is marked: **✅ VERIFIED** (confirmed against proxy-engine source, IANA/RFC, or swift-claw source, and/or reproduced by live probe on the affected Mac) · **🟢 REPRODUCED** (observed empirically on the owner's machine) · **🟠 SETTING-DEPENDENT** (true or false depending on the proxy's configuration; not a universal fact) · **🟣 UNVERIFIED** (inference or vendor default not pinned to a primary source). Date: 2026-07-06.
>
> **How this was produced.** A four-stream multi-agent research workflow (allocation semantics · detection strategies · security threat model · architectural alternatives), each stream adversarially verified by an independent fact-checker that re-ran local network probes and re-read primary source. Claims were cross-checked against mihomo/Clash.Meta and sing-box source + docs, the IANA IPv4 Special-Purpose registry, AsyncHTTPClient source, and swift-claw's own `SSRFGuard`/`WebFetchTool`. One research sub-agent returned placeholder output; its coverage was recovered from its verifier and from the architecture stream, both of which reproduced the same findings independently.

---

## Bottom line

The refusal is **not a bug** — `SSRFGuard` is doing its job. The owner's machine runs a VPN/proxy in **fake-IP** mode: it hijacks DNS and returns synthetic addresses from `198.18.0.0/15` (RFC 2544 benchmarking), then tunnels the real connection to the origin. That range is legitimately on the SSRF blocklist (`SSRFGuard.swift:57`), so every fetch is refused with `blocked_ssrf`, and the model silently degrades to a `web_search` snippet.

Two answers for the owner:

1. **The fake IP (`198.18.0.84`) is dynamic — do not key on it.** Fake IPs are allocated sequentially from a pool and recycled. Only the **pool/range** is durable, so any exemption must target a **CIDR**, never a `/32`.
2. **Auto-allowing the fake-IP pool is safe under swift-claw's single-owner threat model — if scoped to only `198.18.0.0/15`.** Literal private targets (loopback, `169.254.169.254` metadata, RFC-1918) are parsed before DNS and stay blocked; in fake-IP mode a `198.18.x` address egresses through the owner's tunnel and cannot reach the daemon's own loopback/LAN.

**Recommended fix:** a lazy, self-calibrating canary probe that relaxes the guard **only** for a `198.18.0.0/15` refusal **and only** when a fresh probe confirms fake-IP mode is active, plus a manual CIDR-exemption override and a clearer error. The whole-guard "trust the network" toggle is rejected.

---

## The environment (observed)

🟢 REPRODUCED on the affected Mac:

- `blog.jetbrains.com` → `198.18.0.84`, inside `198.18.0.0/15`. DNS is transparently hijacked: `getaddrinfo`, `@1.1.1.1`, and `@8.8.8.8` all return the same fake IP.
- **All** public hosts land in the pool: `github.com`→`.1`, `apple.com`→`.5`, `google.com`→`.181`, `cloudflare.com`→`.182`, `example.com`→`.183`.
- Never-seen hosts get **sequentially-allocated** IPs (`.184/.185/.186` in one run, `.235/.237` later — a global monotonic cursor).
- A given host is stable **within a session** (`.84` across repeated lookups).
- `curl -L https://blog.jetbrains.com/ai/` → **HTTP 200 through `198.18.0.84`**: the fake IP is fully routable; only swift-claw's guard rejects it.
- Transparent **L3 TUN**, not a proxy listener: `scutil --proxy` empty, no `*_proxy` env, no SOCKS/HTTP listener on any port, default route `utun4`, resolver `10.8.0.1`, fake IPs installed as per-host routes on `utun4`. No Clash control API reachable (`:9090/:9091/:6170` empty); no `clash`/`mihomo`/`sing-box` process visible.

The engine could not be positively fingerprinted (no API, no process). The observed low `198.18.0.x` allocations are consistent with **both** mihomo (default pool `198.18.0.1/16`) and sing-box (conventional `198.18.0.0/15`); they only diverge above `198.19.x`, never reached. Treat it as "an unidentified fake-IP resolver in the Clash/sing-box ecosystem, likely bundled in a commercial VPN client." The allocation semantics that drive both answers hold identically across engines.

---

## Q1 — Is the fake IP stable or dynamic?

**Dynamic as a per-domain identifier; only the pool/range is durable.** ✅ VERIFIED

- **Sequential allocation with recycling.** ✅ mihomo `component/fakeip/pool.go`: `offset` starts at `first.Prev()`; `get()` increments it, wraps at the top of the range (`cycle=true`), and deletes/recycles an in-use IP (`DelByIP`). First usable = `gateway.Next().Next().Next()` (default `198.18.0.4`). 🟢 Reproduced: fresh hosts increment sequentially.
- **LRU eviction.** ✅ mihomo default store is an LRU of `Size: 1000` (`config.go`); `pool_test.go` (`TestPool_MaxCacheSize`, `TestPool_DoubleMapping`) asserts a re-queried, evicted domain gets a **different** IP. So >1000 distinct hosts → the least-recently-used domain's IP changes on re-query.
- **Across restart / VPN reconnect.** 🟠 SETTING-DEPENDENT. Persistence (`store-fake-ip` → bbolt cachefile in mihomo; `cache_file.store_fakeip` in sing-box) keeps mappings stable across restart; with it **off**, the in-memory store is volatile and mappings are rebuilt from scratch. Whether this owner's proxy persists was **not** verified (🟣) — no restart was performed and the persistence flag couldn't be read. So "the IP changes on reconnect" is *possible*, not guaranteed.
- **On any fake-ip flush or range change.** ✅ resets the allocator and re-numbers every domain from the pool start.

**Consequence for the fix:** a single-IP allowlist breaks the moment a domain's fake IP rotates. The pool CIDR does not move. `198.18.0.0/15` (already one blocklist row) covers both engine defaults.

---

## Q2 — Can swift-claw auto-detect the pool and allow it?

### Detection strategies (ranked)

1. **Control-API read** (Clash external-controller `:9090` → `GET /configs` → `dns.fake-ip-range`). Most authoritative, but 🟢 **not available here** (API unreachable, no process). Frequently absent in TUN-mode / commercial-VPN setups.
2. **Config-file read** (per-tool paths). Fragile across tools/formats; no identifiable process to locate a config for.
3. **DNS canary probe (tool-agnostic — the viable path).** ✅ Resolve several known-public hosts plus a guaranteed-nonexistent random host; if they all collapse into one small contiguous reserved block (`198.18.0.0/15`) and the nonexistent host gets a sequentially-allocated IP there (not NXDOMAIN), that block is the fake-IP pool. 🟢 Fingerprint reproduced unambiguously. A prompt-injected agent cannot control DNS, so the probe adds negligible attack surface.
4. **macOS system signals** (`scutil --dns`, `utun` default route, resolver `10.8.0.1`). Corroborating only; cannot yield the pool CIDR.

### Is auto-allow safe? Yes, scoped to `198.18.0.0/15`. ✅ VERIFIED

- **`198.18.0.0/15` is IANA "Benchmarking" (RFC 2544), Globally-Reachable = False.** No legitimate public DNS name resolves there, so a hit is an anomaly, not reachable infra.
- **Literal private IPs stay blocked.** ✅ `SystemAddressResolver.resolve` short-circuits IP literals **before** `getaddrinfo` (`SSRFGuard.swift:148-150`), so fake-IP DNS never rewrites `127.0.0.1`, `169.254.169.254`, or RFC-1918; those rows remain in `blockedV4Ranges`. Exempting the `/15` removes only the single benchmarking row.
- **The daemon's own loopback/LAN is not reachable by hostname.** 🟢 A live `127.0.0.1` listener answered a direct `curl`, but DNS-rebinding names (`localtest.me`, `127.0.0.1.nip.io`) got fake IPs and did **not** hit it — the connection egressed in the proxy's namespace. 🟠 This isolation is a property of the owner's current proxy routing, not a universal guarantee; acceptable because the proxy is the owner's own trusted infra.

### The honest caveat

Once `198.18.0.0/15` is exempt, **every** host resolves into it, so the guard's hostname IP-check becomes a **no-op inside that range** — hostname-SSRF defense is fully **delegated to the trusted proxy**. "Preserves full protection" holds only for **literal** targets. This is a real widening, acceptable for a single-owner assistant on the owner's own machine, not a no-op.

### IPv6 edge

🟣 If a proxy also returns a fake IPv6 (e.g. sing-box `inet6_range fc00::/18`), the guard's ULA rule (`fc00::/7`) still blocks it, and a v4-only `/15` exemption would **not** fix the fetch (`WebFetchTool` requires `addresses.allSatisfy(isPublic)`). Observed hosts were v4-only; a complete fix should account for a fake v6 range or force v4-only resolution.

---

## Architectural alternatives (rejected as primary fix)

- **Proxy-aware fetch (SOCKS5h / HTTP CONNECT).** ✅ AsyncHTTPClient supports both as a one-line config, and SOCKS5h forwards the hostname (remote DNS) so the collision would vanish. But: 🟢 **no proxy endpoint exists here** (transparent TUN, no listener); it would **blind** the SSRF guard (the proxy resolves the real destination the daemon can no longer vet — true for HTTP CONNECT too); and AHC's SOCKS **authorization is unimplemented** (no-auth localhost only). Keep as an **optional escape hatch** for users who run a real no-auth SOCKS/mixed inbound; not the default.
- **Connect-time re-validation.** ✅ Does not help: the guard and swift-nio hit the same hijacked resolver (`10.8.0.1`) and get the same stable fake IP. This is a guard **false positive**, not a TOCTOU divergence (the documented resolve-then-connect TOCTOU is real but orthogonal).

---

## Recommended design

Keep the guard strict by default. Add, in order of value:

1. **Lazy fake-IP detection (primary, zero-config).** When a fetch would be refused **specifically** because a resolved address is in `198.18.0.0/15`, run a canary probe (resolve a couple of known-public hosts + one random nonexistent host). If they also land in the benchmark range → fake-IP mode is active → allow this fetch (egress delegated to the tunnel). Every other blocklist row, and all literals, stay hard-blocked. Self-calibrating and always current (survives toggling the VPN mid-session), unlike a startup-only check. Scope the relaxation to the **detected** pool within the benchmark block; never blanket-trust all of `198.18.0.0/15`.
2. **Manual override.** `CLAW_WEBFETCH_EXEMPT_CIDRS` (parsed to CIDRs, threaded into the guard) for non-default pools or a fake IPv6 range.
3. **Diagnosability.** A clearer `blocked_ssrf` message that names the resolved IP + range and flags "looks like a fake-IP VPN/proxy," and a `clawd doctor` check that runs the canary and reports the detected pool.
4. **Rejected:** a whole-guard trust toggle — it would re-expose literal `127.0.0.1` / `169.254.169.254` / RFC-1918, the exact targets fake-IP does **not** protect.

---

## Open items / not verified

- 🟣 Whether **this** proxy persists fake-IP mappings across a real VPN reconnect/restart (Q1 cross-restart behavior is setting-dependent, not proven).
- 🟣 Exact proxy product/engine on the Mac (no API, no process).
- 🟣 Surge / Shadowrocket / Stash / Quantumult X default pools (vendor docs not pinned; conventionally within `198.18.0.0/15`).
- 🟠 The loopback-isolation property is config-dependent on the owner's proxy routing rules.
