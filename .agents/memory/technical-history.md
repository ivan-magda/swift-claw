# Technical history and investigation pointers

Reviewed against the repository on 2026-10-05. Dated observations below are historical evidence,
not new product requirements. Recheck external-tool behavior on the version used by the task.

## Apple speech

The 2026-07-18 probes used macOS 26.5. They found Russian in `DictationTranscriber`'s locale set,
but not `SpeechTranscriber`'s. The observed counts (54 and 30) and the five-locale reservation
limit were host/version observations, not API guarantees. Query the current engine's locale set.

The probes showed that `supportedLocale(equivalentTo:)` alone was not a support check. Current
[AppleSpeechTranscriber](../../Sources/ClawAppleSpeech/AppleSpeechTranscriber.swift) resolves
equivalent tags against each engine's supported set, compares BCP-47 identifiers, and reopens
`AVAudioFile` for each lane so a previous read does not leave it at EOF.

Wrong-language transcripts could look plausible: observed confidence was about 0.02 for English
recognition of Russian and 0.21 for Russian recognition of English, versus at least 0.84/0.96 for
matching dictation/speech models in those samples. The current
[VoiceTranscriptArbiter](../../Sources/ClawCore/Voice/VoiceTranscriptArbiter.swift) holds the
0.3 floor and 0.6 early-accept thresholds. Do not derive new thresholds from text shape alone.
Russian and English fixtures cover the maintainer's bilingual use case.

The July probes found no suitable audio-language identification API for this implementation;
the project uses one transcription lane per configured locale. Use the
[voice guide](../../docs/LOCAL_DEV.md#voice-message-transcription-macos-26) for current setup and
live checks. The original notes also recorded a 48-second first model download and fixtures
generated with system speech then encoded as Ogg/Opus; those are experimental details, not SLAs.

## Related extracted packages

July 2026 notes record extraction of the speech engine into `ivan-magda/swift-speech-lanes`
(`SpeechLanes`) and the address classifier into `ivan-magda/swift-ssrf-guard` (`SSRFGuard`).
swift-claw still owns its implementations; [Package.swift](../../Package.swift) does not depend
on either package. Changes do not propagate between the copies automatically.

The original speech dependency decision cited swift-claw's macOS 15 floor versus the package's
macOS 26 floor. **That reason is obsolete:** swift-claw now targets macOS 26. This migration does
not choose whether to adopt the package. Re-evaluate Linux support, API fit, and implementation
differences if dependency consolidation becomes a task. Historical comparison topics include
asset reservation serialization, cancellation teardown, and model retention; do not assume
the old gap list describes either current implementation.

The SSRF extraction covered the classifier and address types, not the daemon's canonical URL,
fake-IP detection, exfiltration guard, or tool gate. The original rationale for local copies was
their use across `ClawCore` configuration and policy types. Compare current implementations
before porting fixes. July comparison topics included Darwin/Glibc/Musl imports and full-range
boundary tests. A classifier alone does not establish DNS-rebinding protection; the accepted
egress design remains in [architecture §12](../../docs/ARCHITECTURE.md#12-security--trust-model).

## Sandbox probes

The 2026-07-11 `apple/container` 1.1.0 spike established why network selection must be explicit:
omitting it attached the default network. The current
[ContainerInvocation](../../Sources/ClawExec/ContainerInvocation.swift) and
[architecture §13.1](../../docs/ARCHITECTURE.md#131-execute_code-vm-sandbox-inc-5b-macos-inc-6-linux)
include the maintained contract, including `--no-dns` on the no-network path.

Other probe lessons: the bind-mount grammar used `target=` and bare `readonly`; digest references
ran directly; read-only rootfs needed a writable `/tmp`; CPU and memory caps required host-side
inspection because guest values differed. The spike observed roughly 0.82-second warm boot and
22-second cold boot after an init-image fetch. Those measurements do not set current budgets.
Use the maintained [sandbox acceptance checks](../../docs/LOCAL_DEV.md#release-gates--sandbox-code-execution)
instead of the old private design or assumptions about macOS 15 support.

## Telegram draft streaming

The [2026-09-30 investigation](../../docs/research/telegram-streaming-latency-2026-09-30.md)
contains the measurements. On Telegram for macOS 12.10, an early second draft moved first visible
text from roughly 1.5 seconds to 0.45–0.5 seconds after the first draft. It did not move the end
of the client's reveal animation. Skipping the final draft saved about 0.1 second, while measured
streaming transitions added less than 2 ms. These results describe those runs and that client.

The old memory's “not pushed” status is obsolete: the early-second-draft change landed in
`335f8ed8` (PR 240), and the report is tracked. The current
[TelegramRichDraftStreamer](../../Sources/ClawTelegram/Client/TelegramRichDraftStreamer.swift)
honors flood-control holds. Some status lines in the historical report still describe the
pre-merge state; consult Git history and current source for implementation status.

For new cadence ideas, compare on-screen timing with transport logs. Logs alone cannot establish
when a Telegram client displays text. Keep raw recordings and live logs private.

## Group mode

The August event-planning note is superseded by
[architecture §12.1](../../docs/ARCHITECTURE.md#121-group-mode-config-gated-off-by-default).
In particular, its blanket “no approvals” and “no membership checks” rules do not describe
group Coder: Coder submission requires approval and a fresh membership check. Preserve the
separate nonpersonal state root and use the current group guide when operating a deployment.
Private instance identifiers and service commands belong in the optional local notes.
