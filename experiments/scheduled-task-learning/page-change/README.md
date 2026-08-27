# Page-change learning benchmark

This directory contains the frozen-data candidate for the page-change preflight in protocol 0.2.
It does not call a model or modify the Swift runtime.

`claw-eval` is an internal SwiftPM executable target. The package does not declare it in
`Package.products`, and the project does not install or document it as a user command.
`ClawEvaluation` owns the reusable harness logic; the executable target provides its CLI boundary.
The D6 manifest binds the frozen Mach-O under `artifacts/` separately.

The experiment controller materializes one `input.json` from a source fixture and a lesson set.
Only that file enters the task worker's workspace. Gold labels, split metadata, scorer code, and
conformance cases stay outside that workspace.

## Layout

- `sources/` contains the two HTML documents and neutral region IDs for 13 unrelated page families.
- `gold/` contains hidden atom labels, canonical evidence, verdicts, and injection markers.
- `contracts/` fixes split membership, target classes, feedback text, and lesson lint rules.
- `schemas/` defines the task input, task output, source, gold, attempt, lesson, and synthesis shapes.
- `prompts/` contains the byte-frozen task and lesson-synthesis prompts.
- `page_benchmark/` implements materialization, scoring, feedback, synthesis, promotion, and gates.
- `artifacts/` contains one protected `page-bootstrap` and eight thin controller-facing role wrappers.
- `conformance/cases.json` contains exactly 24 known-good and known-bad scorer cases.
- `tests/` checks fixture quotas, leakage controls, scorer behavior, promotion, and gate provenance.

## Deterministic commands

Run all checks from this directory:

```sh
python3 -m unittest discover -s tests -v
```

Validate all fixture, family, leakage, and split-coverage contracts:

```sh
python3 -m page_benchmark.fixtures .
```

Run the exact 24-case scorer corpus (24/24 is required):

```sh
./artifacts/page-conformance .
```

Score one recorded attempt:

```sh
./artifacts/page-scorer score \
  --source sources/development/pc-development-01.source.json \
  --gold gold/development/pc-development-01.gold.json \
  --attempt attempt.json
```

The controller-facing executable roles are fixed as follows:

| Role | Executable |
| --- | --- |
| synthesis input | `artifacts/page-synthesis` |
| dynamic lesson lint | `artifacts/page-lesson-lint` |
| one-shot promotion | `artifacts/page-promotion` |
| development/regression/sealed gates | `artifacts/page-aggregate` |
| plaintext result to aggregate record | `artifacts/page-record` |
| 24-case receipt | `artifacts/page-conformance` |
| per-attempt score | `artifacts/page-scorer` |
| normalized feedback | `artifacts/page-feedback` |

The eight role wrappers delegate to the single protected `page-bootstrap`. It disables bytecode
writes and validates the importable `page_benchmark/*.py` source closure both before and after role
dispatch. D6 must protect the wrapper, bootstrap, and full transitive source closure.

The scorer writes canonical JSON with sorted keys and no insignificant whitespace. It accepts no
network input, clock input, or model judgment.

All tooling in this directory uses only the Python standard library. JSON entry points use the same
strict parser: the root must be exactly one object, duplicate keys are rejected, and Markdown or
surrounding prose is never discarded. Controller-generated page records, carriers, and receipts
use compact sorted UTF-8 JSON followed by exactly one LF. The D6 manifest itself has its separately
frozen no-LF representation; static schemas and contracts remain bound by their exact raw bytes.

## Materialization boundary

`page_benchmark.materialize` copies only `source.task` into the task carrier. The controller adds
the active lesson set under the same schema in clean and lesson-conditioned runs. Source metadata
such as split and family ID never enters `input.json`. Gold files never enter the task workspace.

The common output schema validates the static shape. The scorer then checks the exact task ID,
known region IDs, exhaustive classification of changed regions, evidence consistency, and the
recorded runtime/tool outcome. This second step supplies the fixture-specific constraints that a
single static JSON Schema cannot encode.

## Synthesis boundary

The private controller projection for each development run has exactly `run_id`, `fixture_id`,
`replicate`, `attempt`, `parsed_output`, and `score_result`. The aggregate command reconstructs
that projection from the accepted development-record bundle; an alternate bundle is rejected even
when it would select the same K_page. The synthesis builder requires all three replicates for all
six development fixtures, selects supported target classes mechanically, and writes only run IDs,
development outputs, the atomic ledger, frozen feedback, error definitions, schema, and lint rules
to `synthesis-input.json`.

The lesson linter separately receives a controller-private development bundle containing those run
records plus the six development sources and gold records. It uses them only to verify two-family,
two-replicate support and dynamically reject copied IDs, selectors, names, and literal values. The
bundle never enters the synthesis worker workspace; regression and sealed artifacts are rejected.

Promotion consumes the raw synthesis transcript, not an operator-authored candidate flag. It
requires one semantic candidate, recomputes the exact lint report from the development bundle and
frozen rules, and derives content-addressed candidate, lesson, active-set, and promotion IDs. The
promotion receipt binds the synthesis input, transcript, development bundle, lint rules, lint
report, active artifact, and ordered lesson IDs.

## Gate and receipt boundary

`artifacts/page-aggregate` reads canonical record bundles and emits a content-addressed gate
receipt. Every stage first reruns the frozen 24-case corpus against manifest-bound fixture bytes.
Regression recomputes the development result from the raw development records before accepting its
receipt. Sealed recomputes both development and regression results. A locally edited but
self-consistent predecessor receipt is therefore insufficient.

The command independently derives protocol run order v2 from the approved final manifest digest.
It accepts only the exact canonical derived artifact, including canary topology, counterbalanced
condition order, synthesis placement, and every restart/unseal barrier. Aggregate records must be
in that frozen sequence and bind its stage, block, and attempt keys. Gate receipts bind both the
full freeze commit and the canonical run-order digest. Every scored attempt also needs a nonempty,
stage-wide unique process UUID and conversation ID.

The aggregate command also recomputes each attempt score and carrier digest. Clean attempts must
bind the canonical empty lesson set. Lesson-conditioned attempts must bind the promoted artifact,
promotion receipt, and the exact materialized `input.json` digest. The sealed lifecycle receipt
must name a lesson-conditioned publisher process and a distinct post-restart loader process.
Condition metrics include each replicate mean and protocol dispersion `R_X`, defined as the range
between the largest and smallest replicate mean score.

`artifacts/page-record` is the only controller-facing record sealer. It accepts the approved
manifest, its manifest-bound source and gold paths, and canonical controller-authored `attempt`,
`carrier`, and provenance-only `skeleton` objects. It strict-parses model output, recomputes the
score, and emits the complete closed aggregate record with attempt, carrier, scorer, and score
receipt digests. The skeleton cannot supply computed score fields or fixture/lesson identity.
For sealed runs the controller invokes it only after joint unseal; an envelope is not an accepted
attempt artifact.

```sh
experiments/scheduled-task-learning/page-change/artifacts/page-record \
  --root "$PWD" \
  --manifest experiments/scheduled-task-learning/page-change/freeze/page-manifest.json \
  --approved-manifest-sha256 "$CONTROLLER_VERIFIED_D6_SHA256" \
  --source experiments/scheduled-task-learning/page-change/sources/development/pc-development-01.source.json \
  --gold experiments/scheduled-task-learning/page-change/gold/development/pc-development-01.gold.json \
  --attempt attempt.json \
  --carrier carrier.json \
  --skeleton record-skeleton.json \
  --output development-record.json
```

Example development invocation from the repository root:

```sh
experiments/scheduled-task-learning/page-change/artifacts/page-aggregate development \
  --root "$PWD" \
  --manifest experiments/scheduled-task-learning/page-change/freeze/page-manifest.json \
  --approved-manifest-sha256 "$CONTROLLER_VERIFIED_D6_SHA256" \
  --approved-freeze-commit "$CONTROLLER_VERIFIED_FREEZE_COMMIT" \
  --run-order "$CONTROLLER_DERIVED_RUN_ORDER" \
  --records development-records.json \
  --conformance-receipt conformance-receipt.json \
  --output development-gate-receipt.json
```

The approved manifest digest and freeze commit are controller trust inputs, not operator data. The
runtime controller must obtain them only from the D6 verification receipt and must supply the run
order derived from those exact bytes. The benchmark CLI then rejects substituted manifests,
locally selected order, and reordered result bundles.

The grouped test-intent and non-redundancy map is in `tests/TEST_INTENT.md`.

## Sealed handling

The repository stores sealed sources and labels so D6 can bind their bytes. The experiment
controller must keep this directory outside every task and synthesis workspace. It must withhold
all sealed outputs and scores until clean, lesson-conditioned, and post-restart attempts finish.
