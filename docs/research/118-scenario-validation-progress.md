# Issue #118: local progress tracker

**Issue:** [#118](https://github.com/ivan-magda/swift-claw/issues/118)
**Parent:** [#115](https://github.com/ivan-magda/swift-claw/issues/115)
**Milestone:** M0: Scenario validation and evaluation contract
**Status:** In progress
**Current task:** 1. Hash-bound approval for frozen validation protocol 0.2
**Last updated:** 26 August 2026

This file tracks working detail for #118. The dashboard comment in #115 remains the canonical project status.

## Status legend

- `IN PROGRESS`: current task.
- `PENDING`: waits for an earlier task.
- `DECISION`: waits for the project owner.
- `DONE`: evidence and deliverable exist.

## Sequential task list

| ID | Task | Status | Required owner decision |
|---:|---|---|---|
| 1 | Freeze validation protocol 0.2 and decision gates | IN PROGRESS | Approve the protocol hash, route, staged budget, and learning target |
| 2 | Build the page benchmark and experimental harness | PENDING | Approve the complete page manifest before canary |
| 3 | Run the page preflight | PENDING | Complete one device-flow login for the isolated evaluation profile |
| 4 | Build the dependency benchmark, canonical-fact preprocessor, policy, and scorer | PENDING | Approve ranking grades before artifacts, then approve the complete dependency manifest |
| 5 | Test dependency headroom and lesson transfer | PENDING | None after the dependency manifest approval |
| 6 | Apply the predeclared scenario decision matrix | PENDING | Decide whether to implement or defer the fixed experimental outcome |
| 7 | Write the evaluation contract and decision record | PENDING | Ratify the contract; threshold changes require a new run |
| 8 | Publish results and close #118 | PENDING | Approve the final GitHub publication |

## Task 1: validation protocol

### Checklist

- [x] Read and compare both research reports.
- [x] Update #118 with the revised shortlist and decision gates.
- [x] Update the #115 dashboard and milestone order.
- [x] Inspect the model/runtime configuration available for the experiment.
- [x] Define fixed model, available decoding controls, prompt version, and tool catalog.
- [x] Define repeat count and run-order controls.
- [x] Define page-change metrics and critical failures.
- [x] Define dependency metrics and critical failures.
- [x] Define headroom, controlled-transfer, and evaluator-reliability gates before seeing results.
- [x] Define the temporary untrusted lesson carrier and limited restart-reload claim.
- [x] Define run artifacts, hashes, naming, and provenance.
- [x] Incorporate the owner's review into protocol 0.2.
- [x] Define the complete decision matrix and exact fallback behavior.
- [x] Define one-shot automated lesson synthesis and role isolation.
- [x] Separate canonical dependency facts from learnable policy decisions.
- [x] Define regression and sealed headroom outcomes without post-hoc tuning.
- [x] Define staged manifest approvals and reproducible invalidation.
- [x] Define Responses retry ownership, credential-refresh accounting, streaming-only transport,
  outbound model checks, optional terminal-model validation, and an attempt-wide output cap.
- [x] Complete independent methodology, metrics, and runtime audits of version 0.2 with no remaining
  blockers.
- [x] Receive owner content approval: `Approve protocol version 0.2 as written`.
- [x] Freeze the exact protocol bytes and verify their SHA-256 inside the freeze commit.
- [ ] Obtain hash-bound D1-D4 confirmation citing the protocol SHA-256 and freeze commit below.

### Deliverable

[`docs/research/118-validation-protocol.md`](118-validation-protocol.md)

### Freeze record

- Protocol version: `0.2`
- Protocol SHA-256: `796aeadc62abac0ccf551fb444e054d33973549c6dc158f2d7be6b4727d75948`
- Freeze commit: `fbecff4f6fe13bff19f7ec05e20218e0ed02849a`
- Independent audits: methodology, metrics, and runtime passed with no remaining blockers
- Content approval: received before freeze
- Hash-bound D1-D4 confirmation: pending

## Task 2: page benchmark and experimental harness

### Checklist

- [ ] Create six development HTML pairs.
- [ ] Create three regression HTML pairs.
- [ ] Create four sealed-test HTML pairs.
- [ ] Cover every frozen noise target class in at least two unrelated families per split.
- [ ] Add an embedded-instruction case to regression and sealed splits.
- [ ] Keep related page families in one split and vary concrete noise implementations across splits.
- [ ] Label material changes, cosmetic changes, and the expected verdict.
- [ ] Keep evaluator labels outside the task-agent input.
- [ ] Add the controller-worker lock lifecycle and streaming-only, attempt-wide output-cap, optional
  terminal-model, and retry-control harness seams.
- [ ] Implement page scorer, output schema, synthesis prompt, lesson schema, deterministic linter,
  and frozen error-code-to-feedback generator.
- [ ] Pass all 24 scorer conformance cases.
- [ ] Freeze the canonical page manifest and obtain D6 for its SHA-256.

### Deliverable

Approved page manifest, benchmark bundle, scorer, synthesizer contract, and experimental harness.

## Task 3: page-change preflight

### Checklist

- [ ] Run the unscored runtime and policy canary.
- [ ] Run 18 clean development attempts.
- [ ] Select target classes mechanically and run one isolated lesson-synthesis attempt.
- [ ] Freeze the candidate lesson set and run counterbalanced regression.
- [ ] Run counterbalanced clean and lesson-conditioned sealed conditions without inspection.
- [ ] Fully stop and start a new experimental process.
- [ ] Verify the experimental lesson-artifact digest after restart.
- [ ] Run the post-restart lesson-conditioned sealed condition.
- [ ] Unseal all sealed conditions together and apply the primary FPR and safety gates.
- [ ] Report deterministic bootstrap, sign-flip, provider usage, accounted tokens, sends, duration,
  and all failure classes.

### Deliverable

Page-change preflight report with raw artifacts and a narrowly scoped experimental restart-reload
claim. Production job-scoped lesson persistence remains M4 work.

## Task 4: dependency benchmark, canonical facts, and scorer

### Checklist

- [ ] Verify advisory data coverage and licensing for candidate ecosystems.
- [ ] Select ecosystem coverage from licensing, reproducibility, and fixture-quality criteria.
- [ ] Obtain D5 for the exact ranking-policy digest before fixtures, labels, and scorer are finalized.
- [ ] Freeze advisory snapshots with provenance and hashes.
- [ ] Create manifests, lockfiles, and dependency graphs.
- [ ] Build the deterministic canonical-fact and remediation-option preprocessor.
- [ ] Expose only canonical records and bounded non-authoritative evidence snippets to the task agent.
- [ ] Freeze 10 development, 4 regression, and 6 sealed cases.
- [ ] Cover all five policy target classes in at least two unrelated families per split.
- [ ] Include production/dev, reachability, remediation, ranking, no-action, and injection cases.
- [ ] Define a structured output schema.
- [ ] Implement policy-only primary scoring, target-code recovery, evidence non-regression, safety,
  and paired headroom scoring.
- [ ] Freeze the dependency error-code-to-feedback generator before development outputs exist.
- [ ] Pass all 24 scorer conformance cases.
- [ ] Freeze the canonical dependency manifest and obtain D7 for its SHA-256.

### Deliverable

Approved dependency manifest, canonical-fact benchmark, synthesis contract, and verified scorer.

## Task 5: dependency headroom and controlled lesson-transfer test

### Checklist

- [ ] Run only the 10-case clean development probe with the fixed repeat count.
- [ ] Record output, score, critical flags, provider usage, accounted tokens, sends, duration, and
  configuration digest.
- [ ] Measure run-to-run variance.
- [ ] Select exactly three recurring policy classes by the frozen mechanical rule.
- [ ] Apply the development headroom and invalid-batch gates.
- [ ] Run and lint one isolated synthesis output without manual editing or regeneration.
- [ ] Run counterbalanced clean versus lesson-conditioned regression without revising a failed bundle.
- [ ] Compute paired policy headroom and target-class recovery after joint unseal, applying safety
  before headroom and efficacy.
- [ ] Run counterbalanced clean versus lesson-conditioned sealed comparisons after admission.
- [ ] Repeat the sealed lesson-conditioned condition after a full process restart.
- [ ] Unseal all sealed conditions together and compute `H_sealed` from clean outputs only.
- [ ] Verify policy transfer to new families and zero canonical-fact or safety regression.
- [ ] Report deterministic bootstrap, sign-flip, provider usage, accounted tokens, sends, duration,
  and decision status.

### Deliverable

Clean-baseline, controlled lesson-transfer, and restart report.

## Task 6: scenario outcome

### Checklist

- [ ] Assign each stage `validated`, `rejected`, `inconclusive`, `invalid`, or `incomplete`.
- [ ] Apply the protocol 0.2 decision matrix without reinterpretation.
- [ ] Record the selected main scenario, technical fallback, or next-candidate requirement.
- [ ] Record why each other candidate was rejected, inconclusive, or deferred.
- [ ] Obtain D8 on product implementation or deferral; D8 cannot rename the experimental outcome.

### Deliverable

Fixed experimental outcome and owner product decision.

## Task 7: evaluation contract and decision record

### Checklist

- [ ] Freeze the input contract and snapshot rules.
- [ ] Freeze the output schema.
- [ ] Ratify deterministic scoring and keep semantic quality report-only.
- [ ] Copy forward the approved success, regression, and critical-failure thresholds unchanged.
- [ ] Ratify the already frozen development, regression, and sealed-test split rules.
- [ ] Copy forward the clean, lesson-conditioned, and post-restart lesson-conditioned conditions.
- [ ] Define lesson leakage and anti-memorization checks.
- [ ] Define required run artifacts and observability fields.
- [ ] Confirm that no gate changed after results; otherwise version the protocol and rerun.
- [ ] Obtain D9 owner approval.

### Deliverable

Final decision record and evaluation contract linked from #118.

## Task 8: publish and close

### Checklist

- [ ] Publish the approved decision record.
- [ ] Add an outcome comment to #118 with links to evidence.
- [ ] Check every #118 acceptance criterion.
- [ ] Close #118.
- [ ] Update the #115 dashboard to M1.

## Owner decision log

| ID | Decision | Needed by | Recommended default | Status |
|---|---|---|---|---|
| D1 | Benchmark route and credential boundary | End of task 1 | `openai-chatgpt/gpt-5.6-sol`, streaming-only, outbound model assertion plus terminal validation when supplied, no client fallback, isolated OAuth | PENDING HASH CONFIRMATION |
| D2 | Protocol 0.2 hash and prospective gates | End of task 1 | Approve exact SHA-256 and commit; deterministic endpoints and safety gates only | PENDING HASH CONFIRMATION |
| D3 | Staged execution budget | End of task 1 | Hard caps of 194 task/synthesis attempts and 388 Responses sends; 4.35M accounted-token stopping threshold with a fixed missing-usage proxy and possible unknown one-send usage overshoot | PENDING HASH CONFIRMATION |
| D4 | Dependency learning target | End of task 1 | Harness supplies canonical facts; lessons affect actionability and policy decisions only | PENDING HASH CONFIRMATION |
| D5 | Exact dependency ranking grades | Before Task 4 artifacts | Reachability, runtime scope, and compatible remediation outrank raw severity | OPEN |
| D6 | Page experiment manifest | End of task 2 | Approve canonical manifest SHA-256 and commit before canary | OPEN |
| D7 | Dependency experiment manifest | End of task 4 | Approve canonical manifest SHA-256 and commit before any dependency call | OPEN |
| D8 | Product implementation | Task 6 | Follow the fixed experimental outcome; owner may implement or defer but not rename it | OPEN |
| D9 | Final evaluation contract | Task 7 | Ratify the prospective M3 contract without post-result threshold changes | OPEN |
| D10 | GitHub publication and closure | Task 8 | Publish reviewed artifacts and summaries without secrets | OPEN |

## Work the agent can complete without owner input

- Inspect Swift Claw configuration and code paths.
- Draft the protocol and recommend thresholds.
- Generate synthetic fixtures and hidden labels.
- Build local validators and deterministic scorers.
- Run experiments when the environment exposes the selected model credentials.
- Analyze variance, error classes, leakage, and regressions.
- Draft the validation reports and decision record.

## Owner involvement

The owner needs to:

- approve D1, D2, D3, and D4 for the exact protocol hash and commit;
- approve D6 before page canary;
- complete one interactive OAuth device-flow login in the isolated evaluation state; production
  credential files will not be copied or used;
- approve D5 before dependency artifacts are finalized and D7 before dependency calls;
- make D8 after the decision matrix fixes the experimental outcome;
- approve D9 and D10 before the decision becomes canonical on GitHub.

Protocol 0.2 is frozen and its independent audits passed. No fixture build or model run has started.
Task 1 awaits the hash-bound D1-D4 confirmation recorded in the freeze section above.
