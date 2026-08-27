# Page-change freeze tooling

This package implements the D6 freeze boundary for the page-change experiment. It has three responsibilities:

1. build and verify one canonical, content-addressed manifest over the exact protected closure;
2. derive the realized run order deterministically from the final external manifest SHA-256;
3. verify the immutable D6 approval, Git snapshot, executable, and local runtime binding.

It deliberately does not reimplement benchmark, scorer, fixture, canary, or Swift runtime semantics. Those contracts are owned by the protected `page_benchmark` package, its 24/24 conformance runner, and `ClawEvaluation`. A semantic change therefore changes protected bytes and the manifest digest without creating a second validator here.

## Package boundary

`freeze.py` is only an isolated bootstrap. Under `python -I` it resolves the repository-owned package explicitly and loads it under a unique module name without extending `sys.path`. The manifest protects every package module:

- `contract.py`: fixed identities plus strict JSON/path primitives;
- `artifacts.py`: file closure, SwiftPM, executable, conformance, and replace-disabled Git checks;
- `manifest.py`: descriptor parsing and content-addressed manifest build/verification;
- `run_order.py`: the sole deterministic run-order derivation contract;
- `approval.py`: stored/live D6 approval and local runtime receipts;
- `cli.py`: command parsing and atomic output;
- `__init__.py` and the bootstrap itself.

Adding an unprotected Python module beside these files or adding a benchmark source/wrapper makes closure validation fail. Protected Python closures also reject pre-existing bytecode caches and native extension modules (`__pycache__`, `.pyc`, `.pyo`, `.so`, `.dylib`, and `.pyd`). The isolated bootstraps disable bytecode writes before loading protected repository code.

## Protected closure

The descriptor contains the exact closed category set. Source/resource membership for the `claw-eval` target is recomputed from the transitive SwiftPM closure, with both `claw-eval` and `ClawEvaluation` classified as harness code. Repository directories are closed over all benchmark Python sources, schemas, sources, gold, prompts, contracts, configuration artifacts, wrappers, the protocol, `Package.swift`, and `Package.resolved`.

All executable roles must be regular owner-executable files. The evaluation binary must additionally be a thin Mach-O arm64 file. The committed snapshot must contain every protected file as a `100644 blob`, every executable as a `100755 blob`, and the exact canonical manifest bytes. Every Git command runs with replacement objects disabled.

The protected role wrappers delegate to one protected `page-bootstrap`, which validates the complete importable benchmark Python closure immediately before and after each role invocation. The `page-conformance` role must emit canonical JSON plus one LF and report exactly 24/24 before generation or a full freeze preflight succeeds.

## Non-circular run order

The manifest stores the derivation algorithm/version and frozen split/replicate inputs, not a realized-order file. Once the canonical manifest bytes exist, their external SHA-256 is the seed. `derive-run-order` emits the realized canary/process boundary, scored attempts, synthesis event, counterbalanced condition order, restart barrier, and joint-unseal barrier. The realized order belongs in external run provenance, so no manifest self-reference is introduced.

## Verification flow

Generate and verify locally:

```sh
/usr/bin/python3 -I tools/page_change_freeze/freeze.py generate \
  --repo-root /path/to/swift-claw \
  --descriptor experiments/scheduled-task-learning/page-change/freeze/page-manifest-descriptor.json \
  --output experiments/scheduled-task-learning/page-change/freeze/page-manifest.json

/usr/bin/python3 -I tools/page_change_freeze/freeze.py verify \
  --repo-root /path/to/swift-claw \
  --manifest experiments/scheduled-task-learning/page-change/freeze/page-manifest.json
```

`verify-record-consistency` checks the stored approval record/body and committed snapshot without claiming to contact GitHub.

`verify-live-freeze` is the one-shot batch authorization preflight. It validates the stored D6 binding and then fetches the public issue comment once to check the exact repository, issue, immutable comment and owner IDs, body hash, timestamps, and `updated_at == created_at`. Only after that approval succeeds may the verifier execute SwiftPM or the protected conformance wrapper and validate the commit snapshot, complete verifier closure, and executable binding. The receipt file and stdout contain the same canonical JSON bytes terminated by exactly one LF.

`verify-runtime-binding` is strictly local. Workers use it to bind the approved manifest digest, protected bytes, verifier module closure, executable path/mode/format, and executable hash. It performs no GitHub request and does not repeat the 24-case conformance run.

Derive the realized order:

```sh
/usr/bin/python3 -I tools/page_change_freeze/freeze.py derive-run-order \
  --manifest experiments/scheduled-task-learning/page-change/freeze/page-manifest.json \
  --manifest-sha256 <approved-sha256>
```

## Tests

```sh
PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -m unittest discover \
  -s tools/page_change_freeze/tests
```

`tests/TEST_INTENT.md` maps each retained test to its unique contract mutant and records the deleted duplicated semantic tests.
