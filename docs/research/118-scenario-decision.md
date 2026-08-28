# Issue 118: scenario decision and evaluation contract

**Decision date:** 28 August 2026

**Model route:** `openai-chatgpt/gpt-5.6-sol`

**Protocol:** [version 0.6](118-validation-protocol.md)

**Selected scenario:** scheduled page-change monitoring

## Decision

Use page-change monitoring for the first vertical self-improving scheduled-task implementation.
The dependency and vulnerability prioritization candidate is rejected for this model route because
the clean model scored 100/100 on every development run. It left no observed errors from which to
derive or evaluate a lesson.

This decision has two evidence levels:

| Evidence | Outcome |
|---|---|
| Canonical Protocol 0.6 page controller | `incomplete`; it exhausted its frozen replacement pool during regression |
| Direct page behavior experiment | `exploratory pass`; lessons improved the sealed result and the gain survived fresh-process reload |
| Direct dependency clean headroom probe | `rejected for this route`; `TotalLoss = 0` and `H_dev = 0` |

The direct experiments answer the product question in Issue 118. They do not convert the incomplete
controller batch into a Protocol 0.6 pass. The selected result is model-route-specific and does not
claim that Swift Claw already has a production learning loop.

## Page-change evidence

The canonical controller completed its canary, all 18 clean development attempts, deterministic
target selection, and one-shot lesson synthesis. Transient one-send provider failures then consumed
the frozen replacement pool during regression. The controller recorded `incomplete_batch`; no
quality conclusion comes from that batch.

The follow-up direct experiment used the same frozen page families, task schema, deterministic
scorer, model route, and promoted lesson artifact. It ran one clean, lesson-conditioned, and
fresh-process lesson-conditioned attempt for each of three regression and four sealed fixtures.
All sealed outputs existed before the scorer read sealed gold.

The promoted artifact contained general rules for volatile values and time or build metadata. Its
SHA-256 is `c9c996e80732db61cda2779fdaf09d6a0b198850511c6bf7dc5e90ef48a54578`.

### Sealed result

| Condition | Mean score | Noise suppression | Material recall | Successful fixtures | Critical failures |
|---|---:|---:|---:|---:|---:|
| Clean | 89.375 | 0.8125 | 1.0 | 3/4 | 0 |
| Lesson-conditioned | 100.0 | 1.0 | 1.0 | 4/4 | 0 |
| Fresh-process lesson-conditioned | 100.0 | 1.0 | 1.0 | 4/4 | 0 |

The clean condition treated noise as a material change on two sealed families. Both lesson
conditions removed those false positives without missing a material change. A new process loaded
the persisted lesson bytes and reproduced the lesson-conditioned result.

The direct run used one replicate per fixture, while Protocol 0.6 requires three. Regression also
exposed direct-carrier schema and evidence differences, so its aggregate score is diagnostic only.
The sealed result supports scenario selection but does not support a claim of full Protocol 0.6
conformance.

Evidence digests:

- frozen experiment commit: `0740766897d26b632e5513d72118b2864c6e8744`;
- 21-output digest list SHA-256: `d78d1b483ef412fad09fea301f9003357725b0772805f4045345981dc4ce85e2`;
- deterministic result summary SHA-256: `59ed45a71a2a9d05687e397e82301d9bdc8e96806fb139517f3d1d99d73bb788`.

The output-set digest hashes the UTF-8 list of `<output SHA-256><two spaces><filename><LF>` rows in
lexicographic filename order.

## Dependency evidence

The clean probe used ten development fixtures with three independent fresh-process attempts per
fixture. The model received frozen canonical dependency facts and no lessons. The existing
deterministic scorer evaluated all 30 outputs.

| Metric | Result | Protocol gate |
|---|---:|---:|
| Schema-valid outputs | 30/30 | at least 29/30 |
| Critical outputs | 0/30 | at most 3/30 |
| Mean fixture-median policy score `B` | 100.0 | 50 through 85 |
| Fixture medians below 80 | 0/10 | at least 4/10 |
| Median and maximum within-fixture range | 0.0 / 0.0 | at most 10 / 20 |
| Total policy loss | 0.0 | must exceed 0 |
| Recoverable headroom `H_dev` | 0.0 | at least 10 |
| Selected recurring target classes | 0 | exactly 3 |

Protocol 0.6 states that `TotalLoss = 0` fails the headroom probe. The required outcome is
`dependency rejected for this route`, with no lesson synthesis or held-out dependency run. Running
those stages would manufacture an improvement target after observing a perfect baseline.

Evidence digests:

- dependency output-set digest: `e89305122027beef1e662ced017c394661473c7395576a1209739da3cb64a379`;
- deterministic headroom summary: `c3863577e0b7b5bef88c7e8d6583b410fc9f19bd79bfb394f1954c4ec0595553`;
- Protocol 0.6-bound corpus receipt: `bfe8f652e53671eeb7fcea082aac785015b8c79c5f040b14d6fcf7cb0d968e1e`.

## Evaluation contract

### Input

Each task instance contains:

- a stable task identifier;
- immutable before and after HTML snapshots;
- opaque region identifiers;
- zero to three job-scoped lessons.

The evaluation harness records the occurrence cutoff, source digest, split, and fixture family
outside the model-visible carrier. The model cannot access gold labels, scorer code, split metadata,
or another task's lessons. All compared conditions use the same snapshots, prompt, model route,
tool catalog, and policy path.

Live operation should use a bounded snapshot importer. It fetches owner-approved pages before the
agent run, stores timestamped and hashed local snapshots, and gives the task agent read-only access
to those files. The model does not choose arbitrary URLs or perform external writes.

### Output

The task returns one JSON object with:

- `schema_version` and the exact `task_id`;
- verdict `material`, `cosmetic`, or `none`;
- exhaustive `material_region_ids` and `ignored_region_ids`;
- bounded before and after evidence for every material region.

The checked-in
[`output.schema.json`](../../experiments/scheduled-task-learning/page-change/schemas/output.schema.json)
is authoritative. Extra fields, Markdown, prose outside the object, unknown regions, wrong identity,
or inconsistent evidence make the output invalid.

### Scoring

The deterministic scorer applies:

```text
score = 50 * material_recall
      + 30 * noise_suppression
      + 20 * verdict_accuracy
```

One output succeeds at 90 points or higher when its schema is valid and it has no critical failure.
Critical failures include a missed material change, invented evidence, unsupported material claims,
embedded-instruction compliance, unauthorized tool use, and output-limit failure. Technical run
completion remains separate from task success.

### Comparison and promotion

The next implementation uses a fresh 15 to 20 instance dataset. Related page families remain in one
split, and at least four instances stay held out. The current preflight fixtures remain evidence for
this decision and cannot support a second post-hoc improvement claim.

1. Run the development split three times with an empty lesson set.
2. Generate one bounded candidate lesson set from deterministic development feedback.
3. Admit it only after the regression split passes safety and non-regression gates.
4. Run clean and lesson-conditioned held-out conditions without exposing outputs or gold between
   conditions.
5. Stop the process, load the same lesson-set digest in a new process, and repeat the held-out lesson
   condition.
6. Unseal and score every held-out condition together.

Lessons state reusable rules for volatile values, timestamps, build metadata, and structural churn.
They cannot contain page identifiers, URLs, selectors, proper names, or literal answers. A lesson is
scoped to one scheduled job and cannot enter global memory.

### Success gates

The gates remain those frozen before the experiment:

- lesson and restart material recall: 100%;
- critical failures: zero;
- sealed noise false-positive reduction: at least 20 percentage points and 50% relative to clean;
- verdict accuracy: at least 11/12 outputs;
- lesson successes: at least 9/12 outputs and no lower than clean;
- no clean-success fixture becomes a lesson failure;
- the fresh process loads the exact lesson digest;
- restart false-positive rate rises by no more than 5 percentage points from the pre-restart lesson
  condition.

Changing a threshold after seeing results requires a new evaluation version and a fresh held-out
set.

## Capability work after Issue 118

The vertical implementation needs four contained additions:

1. A deterministic page snapshot importer with an owner-defined URL allowlist and size limits.
2. Job-scoped task instances, evaluations, candidate lessons, and active lesson-set digests.
3. A deterministic promotion gate that rejects critical or regression-causing lessons.
4. Scheduler integration that reloads active lessons after restart and records task quality apart
   from run state.

The first version remains read-only and report-only. It does not edit pages, send messages to third
parties, use global memory for lessons, or weaken approval and egress policy.

## Claim boundary

The result supports this statement:

> On the frozen `gpt-5.6-sol` page-change fixtures, two model-synthesized rules removed observed
> noise false positives without reducing material recall, and a fresh process reproduced the gain
> after loading the same persisted lesson artifact.

It does not prove autonomous production lesson creation, production job-scoped persistence,
statistical generalization beyond the frozen families, or equivalent behavior from another model
route. Those claims belong to the later vertical implementation and its fresh evaluation set.
