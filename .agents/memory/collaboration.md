# Collaboration preferences

Consolidated from maintainer feedback on 2026-10-05. Current task instructions take precedence.

## Communication

- Match the language of the question. Keep code, commits, plans, and maintained documentation
  in English. For Russian replies, use short, literal sentences with one idea each. Explain
  unfamiliar terms and the user-visible effect before referring to internal identifiers.
- When summarizing a plan, state its goal and expected behavior, then explain each item in
  connected prose. Name excluded work and where it belongs. Avoid a list of unexplained symbols.
- Before applying results from a background workflow that is still running, say which results
  have been verified and which parts remain pending.
- Use the `stop-slop` skill, when available, before publishing prose. Review the final draft:
  remove filler, em dashes, vague claims, and forced contrasts. Loading a skill alone is not a
  completed editing pass. Do not add an agent advertising footer.

## Git and publication

- The maintainer chooses the branch. A request to commit on `main` means `main`; do not create
  an unsolicited branch. Describe a branch or PR by the feature, without internal phase numbers.
- Standalone research and reference docs should land on `main`, separate from feature work.
  Honor an explicit target branch and preserve the working tree. This preference does not
  authorize a commit, push, or branch switch unrelated to the current request.
- Before resuming an open PR, fetch and inspect remote changes. The maintainer may have accepted
  review suggestions on GitHub. Treat those edits as the new baseline.
- Preserve unexplained working-tree edits. Check who or what changed the file before editing
  it again; do not restore an older version merely because it matches your earlier intent.
- Stage only intended paths. Inspect the staged diff before committing and the resulting commit
  afterward. Confirm that new directories are visible to Git; broad ignore patterns have hidden
  new source files here before.
- Use version tags for GitHub Actions, following the existing
  [zizmor ref-pin policy](../../.github/zizmor.yml). Do not replace them with SHA pins.
- In GitHub prose, write an external event or phase number without `#` unless an issue reference
  is intended. Use full commit SHAs for commit links.
- Treat swift-claw as software others install. Check supported platforms, release artifacts,
  and onboarding routes. Repository visibility changes and release-tag pushes need authorization
  for that action; an old note about preparing a public release is not authorization.

## Reviews and changes

- Report substantive correctness, security, and contract issues. Skip cosmetic nits unless
  requested. For each finding, identify a reachable user path and account for recovery behavior.
- Evaluate security findings against the actual deployment in
  [architecture §12](../../docs/ARCHITECTURE.md#12-security--trust-model), including the separate
  group-mode exception. Preserve specified fail-closed checks. Do not add speculative hardening
  based only on a scenario that assumes the local host is already compromised.
- Recheck a finding after other edits in the same batch: another fix may make its triggering
  path unreachable. Do not use an obsolete rationale to justify a refactor.
- Prefer readable code over constant-factor optimization unless measurements show a hot path.
- A defaulted clock, interval, or file-manager argument can be an intentional dependency seam
  even when current callers use its default. Preserve that seam and domain-typed parameters
  when removing duplication.

## Documentation and task execution

- Keep principles and conventions in maintained guides. Keep point-in-time audit findings in
  the relevant report, issue, or PR. Product requirements belong in the accepted specification.
- A command change can invalidate a sibling guide. Search the whole public doc set for the
  affected artifact and follow the route a new user would take. State which examples you could
  not execute; do not present them as verified.
- Use `swift-testing-expert` for Swift test work and `swift-concurrency` for concurrency work
  when those skills are available. Repository instructions and specs still govern the result.
- When delegating a numbered plan task, pass relevant preamble constraints too. A task extractor
  may omit them. Read the whole plan and give each obligation an owner.
- Edit shared progress ledgers with a unique section anchor. Repeated task labels are unsafe
  targets for a global substitution.
- Batch independent reads and avoid needless tool round trips. Choose verification by the risks
  in the change; old suite timings or workflow cost measurements do not justify skipping checks.
