# SwiftUI preview spike artifacts

These files preserve the source written during issue
[#179](https://github.com/ivan-magda/swift-claw/issues/179). They are evidence, not supported tools
or production dependencies.

- [`local`](local/README.md) contains the first, superseded local Apple-renderer probe.
- [`dactyl`](dactyl/README.md) contains the selected remote Dactyl probe.

The spike excludes:

- browser profiles, cookies, and login databases;
- Dactyl project identifiers and account data;
- downloaded WebAssembly modules and browser caches;
- compiled applications and renderer binaries;
- temporary Cloudflare tunnel binaries and URLs.
