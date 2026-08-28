# Dependency-prioritization benchmark core

This directory contains the deterministic, artifact-only foundation for the dependency candidate
in protocol 0.3. It normalizes already-frozen dependency facts, scores report-only task outputs,
computes bounded lesson headroom, and validates a 24-case conformance corpus.

Follow-up layers own model calls, OSV ingestion, package-manager parsing, scheduling, dependency
changes, pull requests, and the D7 freeze. This directory stops at deterministic artifacts.
The ranking policy in `contracts/ranking-policy.json` is the owner-approved frozen D5 input; the
benchmark reads its grades directly rather than re-encoding them in Python.

## Layout

- `contracts/` fixes D5 ranking, target ownership, error taxonomy, feedback, and coverage.
- `schemas/` closes the normalized source, canonical task, model input/output, gold, and score shapes.
- `dependency_benchmark/normalization.py` maps author-only source keys to opaque canonical IDs.
- `dependency_benchmark/scorer.py` validates one attempt and coordinates pure component/safety checks.
- `dependency_benchmark/oracle.py` applies only frozen target-owned field transforms and computes headroom.
- `conformance/cases.json` embeds three normalized fixtures and exactly 24 byte-distinct attempts.
- `tests/` covers normalization secrecy, contract closure, feedback, target recurrence, and oracle scope.

`benchmark-core/` is the small scenario-neutral sibling used by both this benchmark and the page
preflight for strict JSON, attempt-carrier validation, feedback normalization, and conformance
bookkeeping. Scenario policy and fixture semantics remain in their own packages.

## Deterministic checks

From this directory:

```sh
scripts/lint.sh
scripts/test.sh
```

Run the exact conformance corpus directly:

```sh
uv run python -B -m dependency_benchmark.conformance .
```

A valid receipt reports exactly 24 passed cases out of 24. The same frozen bytes produce the same
canonical receipt; no network, clock, random seed, LLM judge, or external process is involved.

## Trust boundary

`source.schema.json` describes normalized frozen facts, not live registry data. Materialization
replaces source keys, package names, advisory IDs, and dependency chains with domain-separated,
content-addressed IDs before the task reaches an agent. The scorer accepts only those canonical
references and flags cross-finding or invented IDs as critical.

The mechanical oracle first requires a schema-valid clean output. It can then replace only fields
owned by the selected target classes. A single-field counterfactual can temporarily violate a wire
cross-field constraint (for example, corrected actionability with an unchanged remediation field),
so the already-validated copy is evaluated by the unchanged component scorer without being treated
as a second model output. Invalid clean outputs always have zero recoverable headroom.

A model output is semantically valid only when its remediation queue contains exactly the returned
findings labeled `actionable`. This keeps the frozen D5 ranking component as pure linear-grade nDCG:
an aligned but wrong actionability decision remains lesson-addressable, while a contradictory queue
cannot receive an accidental perfect score from a trailing zero-grade entry.
