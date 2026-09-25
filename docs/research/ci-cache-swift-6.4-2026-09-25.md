# CI cache measurements with Swift 6.4

Investigation for [issue #231](https://github.com/ivan-magda/swift-claw/issues/231),
measured on 2026-09-25.

Keep the existing full `.build` cache on both build/test runners and the full
`BuildTools/.build` lint cache. In the same-source hit comparison, full caching reduced
total job time from 648 to 305 seconds on macOS, 462 to 170 seconds on Linux, and
244 to 103 seconds for lint. These totals include download and extraction. The
repository needs no permanent measurement jobs, matrices, helper scripts, cache-path
changes, or build-backend change for this result.

Dependency-only caching cuts the product archives by about half but recompiles the
sources. It loses to full caching on both platforms. For lint it saves only 25.51 MiB
and still rebuilds SwiftFormat. The larger Swift 6.4 archives buy enough compilation
reuse to retain the simplest existing configuration.

## Cold and restored jobs

All times are wall seconds. “Hit” for the no-cache rows is a second cold control.
“Build” is SwiftPM's reported build time; “job” includes setup, tests, inventory,
cache work, and cleanup. MiB means 1,048,576 bytes.

| Runner / cache | Compressed MiB | Cold job s | Hit job s | Cold → hit build s | Hit restore s |
| --- | ---: | ---: | ---: | ---: | ---: |
| macOS ARM64 / full | 1008.93 | 669 | 305 | 420.7 → 86.9 | 44 |
| macOS ARM64 / dependencies | 484.23 | 570 | 437 | 342.6 → 264.5 | 12 |
| macOS ARM64 / none | — | 430 | 648 | 270.4 → 418.6 | 0 |
| Linux ARM64 / full | 1146.22 | 466 | 170 | 300.9 → 26.1 | 17 |
| Linux ARM64 / dependencies | 485.51 | 454 | 483 | 296.0 → 316.7 | 4 |
| Linux ARM64 / none | — | 456 | 462 | 303.4 → 311.5 | 0 |
| Lint x86_64 / full | 522.17 | 276 | 103 | 133.1 → 0.5 | 6 |
| Lint x86_64 / dependencies | 496.66 | 271 | 236 | 129.6 → 132.2 | 6 |
| Lint x86_64 / none | — | 261 | 244 | 130.6 → 127.3 | 0 |

The macOS cold builds varied from 270.4 to 420.7 seconds despite identical commands
and sources. The second no-cache control took 418.6 seconds to build. These single-run
samples show runner variation; they do not establish a precise speedup distribution.
Full-cache hits still beat both observed no-cache job totals on each platform.

## Transfer, compression, and a subsequent hit

The subsequent full-cache round restores the seed and saves a fresh archive. It
checks that the result survives paying the new-key upload cost as well:

| Runner / full cache | Repeat job s | Repeat build s | Download s | Extract s | Restore step s | Save step s |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| macOS ARM64 | 230 | 60.6 | 11.5 | 14.6 | 26 | 21 |
| Linux ARM64 | 195 | 31.3 | 6.3 | 9.7 | 18 | 10 |
| Lint x86_64 | 131 | 0.5 | 4.2 | 3.7 | 8 | 23 |

Cold saves expose the archive creation/upload cost for each strategy:

| Runner / cache | Exact compressed bytes | Cold save step s | Compression/setup to first progress s | Remaining upload progress s |
| --- | ---: | ---: | ---: | ---: |
| macOS ARM64 / full | 1,057,941,538 | 31 | 24.2 | 5.6 |
| macOS ARM64 / dependencies | 507,756,695 | 14 | 8.7 | 3.9 |
| Linux ARM64 / full | 1,201,901,190 | 10 | 6.0 | 3.6 |
| Linux ARM64 / dependencies | 509,091,372 | 3 | 1.9 | 0.9 |
| Lint x86_64 / full | 547,537,343 | 20 | 19.2 | 0.9 |
| Lint x86_64 / dependencies | 520,789,686 | 18 | 15.8 | 1.5 |

The save-step totals are authoritative. The compression/setup column ends at the first
upload progress message and includes some upload activity; the remaining-progress
column is not the complete upload duration. Download/extraction columns likewise use
log boundaries, while the restore step includes cache lookup and action overhead.
Lint's production key normally gets exact hits and skips saving; its refresh row is
an overhead sensitivity check, not its normal steady-state behavior.

## Compilation reuse

The macOS verbose logs contain 2,248 `builtin-SwiftPerFileCompile` actions and 310
C/C++ source compile actions in each cold build. Dependency-only and no-cache jobs
repeat those actions on the next runner. The full-cache hit contains zero of either;
it retains 36 Swift-driver actions for project/test modules and one link action for
`ClawGatewayTests`. These are visible build-action counts, not source-file or OS
process counts. A cache hit does not mean the whole build graph does no work.

Linux's full hit likewise contains zero per-file Swift, C/C++, or assembly compile
actions, compared with 2,247 Swift, 559 C/C++, and 246 assembly actions in its cold,
dependency-only, and no-cache builds. It retains 53 project Swift-driver and 53 link
labels, while avoiding dependency Swift-driver actions. Its build takes 26.07 seconds,
versus 316.71 seconds with dependency-only caching and 311.53 seconds without a cache.

The counts cover the verbose `Building for debugging...` through `Build complete!`
segment. They match `builtin-SwiftPerFileCompile`, source `Compile` labels, and
`^Link\s`; link-file-list generation is excluded. Driver module names beginning
`Claw` or equal to `clawd` identify project modules.

Lint's full hit reports a 0.51-second SwiftFormat build, versus 132.20 seconds with
dependency-only caching and 127.28 seconds without a cache. Its subsequent full hit
reports 0.48 seconds.

## Where the larger artifacts come from

[Swift 6.4 made Swift Build the default](https://www.swift.org/blog/swift-6.4-released/).
A separate cold probe switches only the backend to `--build-system native` for both
test invocations, retaining the same product revision, Swift 6.4 pins, runner classes,
and full test coverage. The successful
[native macOS job](https://github.com/ivan-magda/swift-claw/actions/runs/36113955643/job/108003535484)
and [native Linux job](https://github.com/ivan-magda/swift-claw/actions/runs/36114812969/job/108006289147)
produce smaller archives:

| Platform | Native archive bytes | Swift Build archive bytes | Difference |
| --- | ---: | ---: | ---: |
| macOS ARM64 | 910,977,043 | 1,057,941,538 | +140.16 MiB (+16.13%) |
| Linux ARM64 | 856,272,186 | 1,201,901,190 | +329.62 MiB (+40.36%) |

The inventory below measures uncompressed regular-file content. It does not assign
compressed archive bytes to individual categories.

| Uncompressed category (MiB) | macOS native | macOS Swift Build | Linux native | Linux Swift Build | Lint Swift Build |
| --- | ---: | ---: | ---: | ---: | ---: |
| Dependency repositories | 432.37 | 432.41 | 432.25 | 432.29 | 494.08 |
| Dependency checkouts | 310.21 | 310.21 | 310.17 | 310.17 | 13.25 |
| Objects / libraries | 347.82 | 447.67 | 537.60 | 744.02 | 65.85 |
| Modules | 301.68 | 556.29 | 152.23 | 204.99 | 20.36 |
| Test executables / libraries | 155.42 | 540.35 | 302.00 | 1291.34 | 0.00 |
| Product executables | 73.54 | 74.70 | 157.86 | 163.69 | 16.08 |
| Debug symbols | 360.12 | 3.13 | 0.00 | 0.00 | 0.00 |
| Index store | 97.43 | 0.00 | 90.82 | 0.00 | 0.00 |
| Build metadata | 161.69 | 166.67 | 108.31 | 129.49 | 4.74 |
| Other | 48.52 | 188.69 | 44.79 | 141.68 | 0.58 |
| **Total logical MiB** | **2288.82** | **2720.13** | **2136.02** | **3417.67** | **614.92** |

Swift Build creates 17 test products on each platform. Linux's `*Tests.so` files total
1,354,064,360 logical bytes, versus 316,666,448 bytes for the native backend's single
`.xctest`: an increase of 1,037,397,912 bytes. Larger objects and modules add to that.
On macOS, the test-product increase is partly offset by much smaller `.dSYM` output;
test products plus debug symbols grow by only 29,299,117 bytes. Modules and objects
account for more of the remaining macOS difference. Dependency storage stays almost
unchanged across backends.

This same-toolchain comparison supports the backend switch as a major cause of the
historical growth, especially on Linux. It does not isolate every effect of the
Swift 6.3-to-6.4 upgrade: compiler/runtime, source revision, runner images, and archive
bytes also differ across the historical runs. The probe is footprint evidence, not
a recommendation to change the production build backend.

Lint has a different storage profile: the SwiftFormat bare Git repository occupies
518,076,010 logical bytes. Its checkout depends on that repository through Git object
alternates and a local origin URL. Omitting the repository would break those references;
that omission is not a validated cache optimization.

## Method

The temporary experiment checks out product revision
[`efcde68ba818b32de80caba72bc95ed47ca31ab9`](https://github.com/ivan-magda/swift-claw/commit/efcde68ba818b32de80caba72bc95ed47ca31ab9)
in each job. It preserves the production runner classes, pinned toolchains, build flags,
and test commands: Linux ARM64 on `ubuntu-24.04-arm` with `swift:6.4.0-noble`, and macOS
ARM64 on `xcode-27` with Xcode 27.0 (`27A266a`). Linux also runs the concurrency-sensitive
suites on one cooperative thread; macOS runs native Coder tests in a separate process.
Lint runs on the existing Linux x86_64 runner/container and checks the canonical gate
and formatter workflow.

Each fresh runner uses one of three cache strategies:

- **Full:** `.build`, or `BuildTools/.build` for lint.
- **Dependencies:** only the corresponding `repositories` and `checkouts` directories.
- **None:** no Actions cache restore or save.

The cold round saves caches under experiment-only keys. The hit round restores those
exact keys and skips saving. The refresh round restores the same keys and saves a new
archive under a new key. Refresh measures the upload overhead of the production
SHA-keyed cache policy with unchanged product sources; it does not simulate a source
edit. Restores fail on a missing key. The cold and hit rounds each include a no-cache
control on a fresh runner. Refresh repeats only the full-cache candidate. The experiment does not change
the ordinary workflow triggers or merge gates.

The explicit `actions/cache/restore@v6` and `actions/cache/save@v6` steps expose their
whole wall times. Those times include transfer and tar/compression work. Log timestamps
also bracket download/extraction and compression/upload, but the first upload progress
message includes setup and some upload time. These subintervals are estimates, not
separately instrumented timings. Build caches use zstd; the lint container uses gzip,
matching production.

The directory inventory counts regular files without following symlinks. Its mutually
exclusive categories separate dependency repositories/checkouts, object files and
libraries, modules, test executables, product executables, debug symbols, index data,
build metadata, and residual files. Logical bytes describe uncompressed file content;
allocated bytes describe filesystem allocation; the cache action reports compressed
archive bytes. They are different measurements. Verbose product build logs provide
compiler-command evidence of reuse. The temporary Linux setup installs Python for the
inventory, and the job totals include that setup and inventory overhead in every arm.

The temporary workflow evolved while fixing reporting: the first attempt lacked Python
in the Swift container, and the next Linux inventory hit Git's container ownership
check. Those failed measurement jobs are excluded. Successful macOS/lint cold jobs
come from the latter run; the Linux cold jobs were repeated after correcting the
revision check. Product sources, pins, and build/test settings stayed fixed. Workflow
heads differ; this is a same-product-revision comparison, not an unchanged-workflow
benchmark. The final probe also recognizes Linux `*Tests.so` as test products.

## Historical archive growth

The issue compares these production uploads/restores:

| Cache | Swift 6.3 compressed bytes | Swift 6.4 compressed bytes | Change |
| --- | ---: | ---: | ---: |
| macOS ARM64 build | 939,372,631 | 1,057,532,471 | +12.58% |
| Linux ARM64 build | 859,710,284 | 1,201,960,948 | +39.81% |
| Linux x86_64 lint | 540,944,273 | 547,572,293 | +1.23% |

Sources: [6.3 CI](https://github.com/ivan-magda/swift-claw/actions/runs/35432916536),
[6.4 CI](https://github.com/ivan-magda/swift-claw/actions/runs/36102418287),
[6.3 lint](https://github.com/ivan-magda/swift-claw/actions/runs/35432916696), and
[6.4 lint](https://github.com/ivan-magda/swift-claw/actions/runs/36102418302).
The source revisions and compilers differ. These numbers establish the archive growth;
they cannot isolate its cause or establish a cache speedup.

## Source runs and reproduction

Use the successful jobs for the named runner group; the mixed cold run also contains
the excluded Linux reporting failures described above.

| Runner group | Cold | Exact hit | Subsequent hit with save |
| --- | --- | --- | --- |
| macOS ARM64 | [36113862788](https://github.com/ivan-magda/swift-claw/actions/runs/36113862788) | [36114964225](https://github.com/ivan-magda/swift-claw/actions/runs/36114964225) | [36115998074](https://github.com/ivan-magda/swift-claw/actions/runs/36115998074) |
| Linux ARM64 | [36114741541](https://github.com/ivan-magda/swift-claw/actions/runs/36114741541) | [36115513303](https://github.com/ivan-magda/swift-claw/actions/runs/36115513303) | [36116326980](https://github.com/ivan-magda/swift-claw/actions/runs/36116326980) |
| Lint x86_64 | [36113862788](https://github.com/ivan-magda/swift-claw/actions/runs/36113862788) | [36114806207](https://github.com/ivan-magda/swift-claw/actions/runs/36114806207) | [36115189371](https://github.com/ivan-magda/swift-claw/actions/runs/36115189371) |

The measurement workflow is retained in commit history:
[cold macOS/lint](https://github.com/ivan-magda/swift-claw/blob/80d6df37/.github/workflows/ci.yml),
[corrected Linux](https://github.com/ivan-magda/swift-claw/blob/5c07382e/.github/workflows/ci.yml),
[final comparison probe](https://github.com/ivan-magda/swift-claw/blob/09db1dd2/.github/workflows/ci.yml),
[native macOS probe](https://github.com/ivan-magda/swift-claw/blob/77037a8c/.github/workflows/ci.yml),
and [corrected native Linux probe](https://github.com/ivan-magda/swift-claw/blob/479e0733/.github/workflows/ci.yml).
To reproduce, use a temporary branch, a fresh experiment cache namespace, and run cold,
hit, then refresh for each runner group. The final comparison probe pins its seed-key
namespace to the original measurement revision; replace that namespace for a new study.

Actions job/step timestamps supply total times. Timestamped cache logs supply archive
bytes and transfer intervals. `ARTIFACT_CATEGORIES`, `ARTIFACT_TOP_DIRECTORIES`, and
`ARTIFACT_LARGEST_FILES` in each inventory step supply the directory breakdown.
The environment step records workspace paths, architecture, and initial shared SwiftPM
cache sizes; those shared caches are outside the cached paths.

Cache availability remains a separate concern. Historical runs include a later miss
on a previously saved lint key, and repository inventory showed duplicate archives
across PR refs. Those observations do not prove eviction or justify a new retention
policy. This study measures successful restore performance, not a long-run hit rate.

## Validation

The comparison completed nine cold jobs, nine restored/control jobs, and three
subsequent full-cache jobs with the production test or lint commands passing.
Both native-backend footprint jobs also passed. No Swift source, tests, toolchain
pins, production workflows, or public commands changed. The final change is this
report; pinned actionlint, zizmor, and ShellCheck checks passed locally.

The temporary remote branches and all 12 experiment caches (9,426,581,273 bytes) were
removed after measurement.
