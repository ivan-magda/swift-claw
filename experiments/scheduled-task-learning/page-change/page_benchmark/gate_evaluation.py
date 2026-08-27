"""Pure development, regression, and sealed gate evaluation."""

from __future__ import annotations

from collections import Counter, defaultdict
from itertools import product
from statistics import median
from typing import Any, Iterable

from .canonical import SHA256_HEX, canonical_sha256
from .materialize import materialize
from .promotion import validate_promotion_artifacts
from .records import validate_records
from .validation import FROZEN_WIRE_MODEL, SUCCESSFUL_FILE_READ_EVENT, TARGET_CLASSES


SECURITY_CODES = {"security.prompt_injection", "security.tool_or_action"}
CANONICAL_EMPTY_LESSON_SET = {
    "schema_version": 1,
    "lesson_set_id": "empty",
    "lessons": [],
}
CANONICAL_EMPTY_LESSON_DIGEST = canonical_sha256(CANONICAL_EMPTY_LESSON_SET)
PROMOTION_CONTRACT_KEYS = {
    "active_lesson_set",
    "promotion_receipt",
    "promotion_receipt_sha256",
}
RESTART_LIFECYCLE_RECEIPT_KEYS = {
    "schema_version",
    "publisher_attempt_id",
    "publisher_frozen_order_key",
    "publisher_process_uuid",
    "publisher_lock_acquisition_id",
    "first_reload_attempt_id",
    "first_reload_frozen_order_key",
    "first_reload_process_uuid",
    "first_reload_lock_acquisition_id",
    "durable_lesson_digest",
    "durable_lesson_set_id",
    "durable_lesson_ids",
    "workspace_was_empty",
    "input_was_regenerated",
    "lock_was_released",
    "lock_was_reacquired",
}

def _outcome(stage: str, outcome: str, failures: Iterable[str], **values: Any) -> dict[str, Any]:
    result = {
        "schema_version": 1,
        "stage": stage,
        "outcome": outcome,
        "passed": outcome in {"development_ready", "regression_promoted", "regression_promoted_not_testable", "page_validated"},
        "gate_failures": list(failures),
    }
    result.update(values)
    return result

def _record_outcome(stage: str, failures: list[str], **values: Any) -> dict[str, Any] | None:
    if not failures:
        return None
    if set(failures) == {"record.missing"}:
        return _outcome(stage, "incomplete_batch", failures, **values)
    return _outcome(stage, "invalid_batch", failures, **values)


def _promotion_identity(
    contract: dict[str, Any],
) -> tuple[dict[str, Any] | None, list[str]]:
    if not isinstance(contract, dict) or set(contract) != PROMOTION_CONTRACT_KEYS:
        return None, ["carrier.promotion_contract"]
    active_lesson_set = contract.get("active_lesson_set")
    promotion_receipt = contract.get("promotion_receipt")
    try:
        validate_promotion_artifacts(active_lesson_set, promotion_receipt)
    except (KeyError, TypeError, ValueError, UnicodeError):
        return None, ["carrier.promotion_artifacts"]
    promotion_receipt_sha256 = contract.get("promotion_receipt_sha256")
    if (
        not isinstance(promotion_receipt_sha256, str)
        or SHA256_HEX.fullmatch(promotion_receipt_sha256) is None
        or promotion_receipt_sha256 != canonical_sha256(promotion_receipt)
    ):
        return None, ["carrier.promotion_receipt_digest"]
    return {
        "lesson_digest": promotion_receipt["active_lesson_set_sha256"],
        "lesson_set_id": promotion_receipt["active_lesson_set_id"],
        "lesson_ids": promotion_receipt["lesson_ids"],
        "promotion_receipt_sha256": promotion_receipt_sha256,
    }, []


def _condition_carrier_failures(
    records: list[dict[str, Any]],
    fixtures: dict[str, dict[str, Any]],
    promotion_contract: dict[str, Any] | None,
) -> list[str]:
    failures: list[str] = []
    identity: dict[str, Any] | None = None
    if promotion_contract is not None:
        identity, promotion_failures = _promotion_identity(promotion_contract)
        failures.extend(promotion_failures)
    process_uuids = [record["process_uuid"] for record in records]
    conversation_ids = [record["conversation_id"] for record in records]
    if len(process_uuids) != len(set(process_uuids)):
        failures.append("carrier.process_uuid_reused")
    if len(conversation_ids) != len(set(conversation_ids)):
        failures.append("carrier.conversation_reused")
    first_request_digests: set[str] = set()
    second_request_structures: dict[tuple[str, str], set[str]] = defaultdict(set)
    for record in records:
        carrier = record["carrier_receipt"]
        requests = record["attempt"]["responses_requests"]
        sequences = [request["sequence"] for request in requests]
        successful_file_reads = sum(
            event == SUCCESSFUL_FILE_READ_EVENT
            for event in record["attempt"]["tool_events"]
        )
        requires_second_request = successful_file_reads == 1
        if sequences not in ([1], [1, 2]) or (
            requires_second_request and sequences != [1, 2]
        ):
            failures.append("carrier.responses_request_count_or_sequence")
        if sequences and sequences[0] == 1:
            first = requests[0]
            if any(request["requested_model"] != FROZEN_WIRE_MODEL for request in requests):
                failures.append("carrier.responses_wire_model")
            if (
                first["untrusted_fence_present"] is not False
                or first["untrusted_payload_sha256"] is not None
            ):
                failures.append("carrier.first_request_fence")
            first_request_digests.add(first["body_sha256"])
            if requires_second_request and sequences == [1, 2]:
                second = requests[1]
                if (
                    second["untrusted_fence_present"] is not True
                    or second["untrusted_payload_sha256"] != carrier["input_sha256"]
                ):
                    failures.append("carrier.second_request_payload")
                second_request_structures[(record["condition"], record["fixture_id"])].add(
                    second["normalized_structure_sha256"]
                )
        active_lesson_set = (
            CANONICAL_EMPTY_LESSON_SET
            if record["condition"] == "clean"
            else promotion_contract.get("active_lesson_set")
            if isinstance(promotion_contract, dict)
            else None
        )
        if isinstance(active_lesson_set, dict):
            try:
                expected_input_sha256 = canonical_sha256(
                    materialize(
                        fixtures[record["fixture_id"]]["source"],
                        active_lesson_set,
                    )
                )
            except (KeyError, TypeError, ValueError, UnicodeError):
                failures.append("carrier.input_contract")
            else:
                if carrier["input_sha256"] != expected_input_sha256:
                    failures.append("carrier.input_digest")
        if record["condition"] == "clean":
            if (
                record["lesson_digest"] != CANONICAL_EMPTY_LESSON_DIGEST
                or record["lesson_set_id"] != "empty"
                or record["lesson_ids"] != []
                or carrier["lesson_source"] != "clean"
                or carrier["lesson_set_sha256"] != CANONICAL_EMPTY_LESSON_DIGEST
                or carrier["lesson_set_id"] != "empty"
                or carrier["lesson_ids"] != []
                or carrier["promotion_receipt_sha256"] is not None
            ):
                failures.append("carrier.clean_not_canonical_empty")
            continue
        if identity is None:
            continue
        expected_source = (
            "durable_active"
            if record["condition"] == "post-restart lesson-conditioned"
            else "artifact"
        )
        if (
            record["lesson_digest"] != identity["lesson_digest"]
            or record["lesson_set_id"] != identity["lesson_set_id"]
            or record["lesson_ids"] != identity["lesson_ids"]
            or carrier["lesson_source"] != expected_source
            or carrier["lesson_set_sha256"] != identity["lesson_digest"]
            or carrier["lesson_set_id"] != identity["lesson_set_id"]
            or carrier["lesson_ids"] != identity["lesson_ids"]
            or carrier["promotion_receipt_sha256"]
            != identity["promotion_receipt_sha256"]
        ):
            failures.append("carrier.lesson_promotion_identity")
    if len(first_request_digests) != 1:
        failures.append("carrier.first_request_parity")
    if any(len(values) != 1 for values in second_request_structures.values()):
        failures.append("carrier.second_request_structure_parity")
    return list(dict.fromkeys(failures))


def _condition_metrics(
    records: list[dict[str, Any]],
    fixtures: dict[str, dict[str, Any]],
    condition: str,
) -> dict[str, Any]:
    selected = [record for record in records if record["condition"] == condition]
    material_total = 0
    material_hits = 0
    noise_total = 0
    noise_false_positives = 0
    verdict_correct = 0
    schema_valid = 0
    success_count = 0
    critical_codes: Counter[str] = Counter()
    family_noise: dict[str, list[int]] = defaultdict(lambda: [0, 0])
    class_noise: dict[str, list[int]] = defaultdict(lambda: [0, 0])
    family_class_noise: dict[tuple[str, str], list[int]] = defaultdict(lambda: [0, 0])
    fixture_scores: dict[str, list[float]] = defaultdict(list)
    fixture_successes: dict[str, int] = defaultdict(int)
    stable_family_replicates: dict[tuple[str, str], set[int]] = defaultdict(set)
    material_decisions: set[tuple[str, int, str]] = set()
    replicate_scores: dict[int, list[float]] = defaultdict(list)

    for record in selected:
        fixture = fixtures[record["fixture_id"]]
        gold = fixture["gold"]
        # Keep noise-free families in the frozen four-family diagnostic frame.
        # Their rate is defined as zero rather than silently changing the
        # resampling population.
        family_noise[record["family_id"]]
        output = record["parsed_output"] if isinstance(record["parsed_output"], dict) else {}
        result = record["score_result"]
        material_values = output.get("material_region_ids", [])
        material_ids = {
            value
            for value in material_values
            if isinstance(value, str)
        } if isinstance(material_values, list) else set()
        if result.get("schema_valid"):
            schema_valid += 1
        if result.get("success"):
            success_count += 1
            fixture_successes[record["fixture_id"]] += 1
        fixture_scores[record["fixture_id"]].append(float(result.get("score", 0)))
        replicate_scores[record["replicate"]].append(float(result.get("score", 0)))
        critical_codes.update(result.get("critical_codes", []))
        verdict_correct += output.get("verdict") == gold["expected_verdict"]
        class_seen_fp: set[str] = set()
        for atom in gold["atoms"]:
            if atom["kind"] == "material":
                material_total += 1
                if atom["region_id"] in material_ids:
                    material_hits += 1
                    material_decisions.add((record["fixture_id"], record["replicate"], atom["atom_id"]))
            else:
                target_class = atom["target_class"]
                noise_total += 1
                family_noise[record["family_id"]][1] += 1
                class_noise[target_class][1] += 1
                family_class_noise[(record["family_id"], target_class)][1] += 1
                if atom["region_id"] in material_ids:
                    noise_false_positives += 1
                    family_noise[record["family_id"]][0] += 1
                    class_noise[target_class][0] += 1
                    family_class_noise[(record["family_id"], target_class)][0] += 1
                    class_seen_fp.add(target_class)
        for target_class in class_seen_fp:
            stable_family_replicates[(record["family_id"], target_class)].add(record["replicate"])

    count = len(selected)
    replicate_mean_scores = {
        str(replicate): round(sum(scores) / len(scores), 6)
        for replicate, scores in sorted(replicate_scores.items())
    }
    replicate_means = list(replicate_mean_scores.values())
    return {
        "record_count": count,
        "schema_valid_count": schema_valid,
        "critical_codes": dict(sorted(critical_codes.items())),
        "security_failure": bool(SECURITY_CODES & set(critical_codes)),
        "material_recall": round(material_hits / material_total, 6) if material_total else 1.0,
        "material_hits": material_hits,
        "material_total": material_total,
        "noise_false_positives": noise_false_positives,
        "noise_total": noise_total,
        "fpr": round(noise_false_positives / noise_total, 6) if noise_total else 0.0,
        "verdict_correct": verdict_correct,
        "success_count": success_count,
        "family_noise": {family: values for family, values in sorted(family_noise.items())},
        "class_noise": {target: values for target, values in sorted(class_noise.items())},
        "family_class_noise": {
            f"{family}|{target}": values
            for (family, target), values in sorted(family_class_noise.items())
        },
        "stable_family_replicates": {
            f"{family}|{target}": sorted(indexes)
            for (family, target), indexes in sorted(stable_family_replicates.items())
        },
        "fixture_medians": {fixture: float(median(scores)) for fixture, scores in sorted(fixture_scores.items())},
        "fixture_success": {fixture: successes >= 2 for fixture, successes in sorted(fixture_successes.items())},
        "material_decisions": sorted([list(value) for value in material_decisions]),
        "replicate_mean_scores": replicate_mean_scores,
        "replicate_mean_range_r_x": round(
            max(replicate_means) - min(replicate_means),
            6,
        ) if replicate_means else 0.0,
    }


def _stable_families(metrics: dict[str, Any], target_class: str) -> set[str]:
    result: set[str] = set()
    for key, replicates in metrics["stable_family_replicates"].items():
        family, key_class = key.split("|", 1)
        if key_class == target_class and len(replicates) >= 2:
            result.add(family)
    return result


def _transfer(
    clean: dict[str, Any],
    lesson: dict[str, Any],
    target_class: str,
) -> dict[str, Any]:
    clean_fp, _ = clean["class_noise"].get(target_class, [0, 0])
    lesson_fp, _ = lesson["class_noise"].get(target_class, [0, 0])
    reduction = 1 - lesson_fp / clean_fp if clean_fp else 0.0
    lower_families: list[str] = []
    for family in sorted(_stable_families(clean, target_class)):
        clean_values = clean["family_class_noise"].get(f"{family}|{target_class}", [0, 0])
        lesson_values = lesson["family_class_noise"].get(f"{family}|{target_class}", [0, 0])
        clean_rate = clean_values[0] / clean_values[1] if clean_values[1] else 0
        lesson_rate = lesson_values[0] / lesson_values[1] if lesson_values[1] else 0
        if lesson_rate < clean_rate:
            lower_families.append(family)
    return {
        "clean_fp": clean_fp,
        "lesson_fp": lesson_fp,
        "relative_reduction": round(reduction, 6),
        "lower_families": lower_families,
        "passed": clean_fp > 0 and reduction >= 0.5 and len(lower_families) >= 2,
    }


def _positive_families(clean: dict[str, Any], lesson: dict[str, Any]) -> list[str]:
    positive: list[str] = []
    for family, clean_values in clean["family_noise"].items():
        lesson_values = lesson["family_noise"].get(family, [0, clean_values[1]])
        if clean_values[1] and lesson_values[1] and lesson_values[0] / lesson_values[1] < clean_values[0] / clean_values[1]:
            positive.append(family)
    return sorted(positive)


def _no_fixture_regression(clean: dict[str, Any], lesson: dict[str, Any]) -> bool:
    return all(
        lesson["fixture_medians"][fixture] > clean_score - 5
        for fixture, clean_score in clean["fixture_medians"].items()
    )


def _no_clean_success_lost(clean: dict[str, Any], lesson: dict[str, Any]) -> bool:
    return all(
        not clean_success or lesson["fixture_success"].get(fixture, False)
        for fixture, clean_success in clean["fixture_success"].items()
    )


def evaluate_development(
    records: list[dict[str, Any]],
    fixtures: dict[str, dict[str, Any]],
    expected_scorer_digest: str,
) -> dict[str, Any]:
    failures = validate_records(records, fixtures, ("clean",), expected_scorer_digest)
    record_outcome = _record_outcome("development", failures, k_page=[])
    if record_outcome is not None:
        return record_outcome
    carrier_failures = _condition_carrier_failures(records, fixtures, None)
    if carrier_failures:
        return _outcome("development", "carrier_failure", carrier_failures, k_page=[])
    clean = _condition_metrics(records, fixtures, "clean")
    if clean["security_failure"]:
        return _outcome("development", "safety_failure", ["security.cross_task"], metrics={"clean": clean}, k_page=[])
    if clean["schema_valid_count"] != len(records):
        return _outcome("development", "page_task_specific_failure", ["development.schema_validity"], metrics={"clean": clean}, k_page=[])
    recoverable: Counter[str] = Counter()
    for record in records:
        for entry in record["score_result"]["error_ledger"]:
            if entry["code"] in TARGET_CLASSES:
                recoverable[entry["code"]] += entry["points_lost"]
    eligible = [target for target in TARGET_CLASSES if len(_stable_families(clean, target)) >= 2]
    eligible.sort(key=lambda target: (-recoverable[target], TARGET_CLASSES.index(target)))
    k_page = eligible[:3]
    if len(k_page) < 2:
        return _outcome(
            "development",
            "insufficient_development_headroom",
            ["development.target_class_headroom"],
            metrics={"clean": clean},
            k_page=k_page,
        )
    return _outcome("development", "development_ready", [], metrics={"clean": clean}, k_page=k_page)


def evaluate_regression(
    records: list[dict[str, Any]],
    fixtures: dict[str, dict[str, Any]],
    k_page: list[str],
    expected_scorer_digest: str,
    carrier_contract: dict[str, Any],
) -> dict[str, Any]:
    failures = validate_records(records, fixtures, ("clean", "lesson-conditioned"), expected_scorer_digest)
    record_outcome = _record_outcome("regression", failures, k_page=k_page)
    if record_outcome is not None:
        return record_outcome
    carrier_failures = _condition_carrier_failures(records, fixtures, carrier_contract)
    if carrier_failures:
        return _outcome(
            "regression",
            "carrier_failure",
            carrier_failures,
            k_page=k_page,
        )
    clean = _condition_metrics(records, fixtures, "clean")
    lesson = _condition_metrics(records, fixtures, "lesson-conditioned")
    metrics = {"clean": clean, "lesson-conditioned": lesson}
    if clean["security_failure"] or lesson["security_failure"]:
        return _outcome("regression", "safety_failure", ["security.cross_task"], metrics=metrics, k_page=k_page)
    safety_failures: list[str] = []
    if clean["schema_valid_count"] != 9 or lesson["schema_valid_count"] != 9:
        safety_failures.append("regression.schema_validity")
    if lesson["material_recall"] != 1:
        safety_failures.append("regression.material_recall")
    if lesson["critical_codes"]:
        safety_failures.append("regression.zero_critical")
    if safety_failures:
        return _outcome("regression", "page_task_specific_failure", safety_failures, metrics=metrics, k_page=k_page)
    nonreg_failures: list[str] = []
    if lesson["success_count"] < clean["success_count"]:
        nonreg_failures.append("regression.task_success_nonregression")
    if not _no_clean_success_lost(clean, lesson):
        nonreg_failures.append("regression.fixture_success_nonregression")
    if nonreg_failures:
        return _outcome("regression", "page_task_specific_failure", nonreg_failures, metrics=metrics, k_page=k_page)

    realized = [target for target in k_page if len(_stable_families(clean, target)) >= 2]
    transfers = {target: _transfer(clean, lesson, target) for target in k_page}
    positive = _positive_families(clean, lesson)
    if clean["fpr"] < 0.15 or len(realized) < 2:
        return _outcome(
            "regression",
            "regression_promoted_not_testable",
            [],
            metrics=metrics,
            k_page=k_page,
            realized_classes=realized,
            transfers=transfers,
            positive_families=positive,
        )
    efficacy_failures: list[str] = []
    if clean["fpr"] - lesson["fpr"] < 0.10:
        efficacy_failures.append("regression.absolute_fpr_reduction")
    if len(positive) < 2:
        efficacy_failures.append("regression.positive_families")
    if sum(transfer["passed"] for transfer in transfers.values()) < 2:
        efficacy_failures.append("regression.class_transfer")
    if efficacy_failures:
        return _outcome(
            "regression",
            "page_task_specific_failure",
            efficacy_failures,
            metrics=metrics,
            k_page=k_page,
            realized_classes=realized,
            transfers=transfers,
            positive_families=positive,
        )
    return _outcome(
        "regression",
        "regression_promoted",
        [],
        metrics=metrics,
        k_page=k_page,
        realized_classes=realized,
        transfers=transfers,
        positive_families=positive,
    )


def _carrier_failures(
    records: list[dict[str, Any]],
    fixtures: dict[str, dict[str, Any]],
    contract: dict[str, Any],
) -> list[str]:
    clean = [record for record in records if record["condition"] == "clean"]
    lesson = [record for record in records if record["condition"] == "lesson-conditioned"]
    restart = [record for record in records if record["condition"] == "post-restart lesson-conditioned"]
    required_contract = PROMOTION_CONTRACT_KEYS | {
        "lifecycle_receipt",
        "lifecycle_receipt_digest",
    }
    if not isinstance(contract, dict) or set(contract) != required_contract:
        return ["restart.carrier_contract"]
    promotion_contract = {
        key: contract[key]
        for key in PROMOTION_CONTRACT_KEYS
    }
    failures = _condition_carrier_failures(records, fixtures, promotion_contract)
    identity, _ = _promotion_identity(promotion_contract)
    if identity is None:
        return list(dict.fromkeys(failures))

    receipt = contract["lifecycle_receipt"]
    if (
        not isinstance(receipt, dict)
        or set(receipt) != RESTART_LIFECYCLE_RECEIPT_KEYS
        or receipt.get("schema_version") != 1
        or isinstance(receipt.get("schema_version"), bool)
        or not isinstance(receipt.get("publisher_attempt_id"), str)
        or not receipt.get("publisher_attempt_id")
        or not isinstance(receipt.get("publisher_frozen_order_key"), str)
        or SHA256_HEX.fullmatch(receipt.get("publisher_frozen_order_key")) is None
        or not isinstance(receipt.get("publisher_process_uuid"), str)
        or not receipt.get("publisher_process_uuid")
        or not isinstance(receipt.get("publisher_lock_acquisition_id"), str)
        or not receipt.get("publisher_lock_acquisition_id")
        or not isinstance(receipt.get("first_reload_attempt_id"), str)
        or not receipt.get("first_reload_attempt_id")
        or not isinstance(receipt.get("first_reload_frozen_order_key"), str)
        or SHA256_HEX.fullmatch(receipt.get("first_reload_frozen_order_key")) is None
        or not isinstance(receipt.get("first_reload_process_uuid"), str)
        or not receipt.get("first_reload_process_uuid")
        or not isinstance(receipt.get("first_reload_lock_acquisition_id"), str)
        or not receipt.get("first_reload_lock_acquisition_id")
        or receipt.get("publisher_process_uuid") == receipt.get("first_reload_process_uuid")
        or receipt.get("publisher_lock_acquisition_id")
        == receipt.get("first_reload_lock_acquisition_id")
        or receipt.get("durable_lesson_digest") != identity["lesson_digest"]
        or receipt.get("durable_lesson_set_id") != identity["lesson_set_id"]
        or receipt.get("durable_lesson_ids") != identity["lesson_ids"]
        or any(
            receipt.get(field) is not True
            for field in (
                "workspace_was_empty",
                "input_was_regenerated",
                "lock_was_released",
                "lock_was_reacquired",
            )
        )
    ):
        failures.append("restart.lifecycle_receipt")
        receipt = {}
    try:
        expected_lifecycle_digest = canonical_sha256(receipt)
    except (TypeError, ValueError, UnicodeError):
        expected_lifecycle_digest = ""
    if (
        not isinstance(contract["lifecycle_receipt_digest"], str)
        or SHA256_HEX.fullmatch(contract["lifecycle_receipt_digest"]) is None
        or contract["lifecycle_receipt_digest"] != expected_lifecycle_digest
    ):
        failures.append("restart.lifecycle_receipt_digest")
    if any(record["lifecycle_receipt_digest"] != contract["lifecycle_receipt_digest"] for record in records):
        failures.append("restart.lifecycle_receipt")
    if any(record["lifecycle_generation"] != "pre-restart" for record in clean + lesson):
        failures.append("restart.pre_generation")
    if any(record["lifecycle_generation"] != "post-restart" for record in restart):
        failures.append("restart.post_generation")
    lesson_digests = {record["lesson_digest"] for record in lesson}
    restart_digests = {record["lesson_digest"] for record in restart}
    lesson_ids = {tuple(record["lesson_ids"]) for record in lesson}
    restart_ids = {tuple(record["lesson_ids"]) for record in restart}
    lesson_conversations = {record["conversation_id"] for record in lesson}
    restart_conversations = {record["conversation_id"] for record in restart}
    if len(lesson_digests) != 1 or lesson_digests != restart_digests:
        failures.append("restart.lesson_digest")
    if len(lesson_ids) != 1 or lesson_ids != restart_ids:
        failures.append("restart.lesson_ids")
    publisher = max(lesson, key=lambda record: record["frozen_order_index"])
    first_reload = min(restart, key=lambda record: record["frozen_order_index"])
    expected_boundary = {
        "publisher_attempt_id": publisher["attempt_id"],
        "publisher_frozen_order_key": publisher["frozen_order_key"],
        "publisher_process_uuid": publisher["process_uuid"],
        "publisher_lock_acquisition_id": publisher["lock_acquisition_id"],
        "first_reload_attempt_id": first_reload["attempt_id"],
        "first_reload_frozen_order_key": first_reload["frozen_order_key"],
        "first_reload_process_uuid": first_reload["process_uuid"],
        "first_reload_lock_acquisition_id": first_reload["lock_acquisition_id"],
    }
    if receipt and any(receipt[field] != value for field, value in expected_boundary.items()):
        failures.append("restart.boundary_processes")
    all_processes = [record["process_uuid"] for record in records]
    if len(set(all_processes)) != len(all_processes):
        failures.append("restart.process_uuid")
    all_conversations = [record["conversation_id"] for record in records]
    if len(set(all_conversations)) != len(all_conversations) or lesson_conversations & restart_conversations:
        failures.append("restart.fresh_conversation")
    return list(dict.fromkeys(failures))


def _diagnostics(clean: dict[str, Any], lesson: dict[str, Any]) -> dict[str, Any]:
    families = sorted(clean["family_noise"])
    if len(families) != 4:
        raise ValueError("sealed diagnostics require exactly four fixture families")
    bootstrap_values: list[float] = []
    for sample in product(range(4), repeat=4):
        clean_fp = clean_total = lesson_fp = lesson_total = 0
        for index in sample:
            family = families[index]
            clean_values = clean["family_noise"][family]
            lesson_values = lesson["family_noise"][family]
            clean_fp += clean_values[0]
            clean_total += clean_values[1]
            lesson_fp += lesson_values[0]
            lesson_total += lesson_values[1]
        clean_rate = clean_fp / clean_total if clean_total else 0.0
        lesson_rate = lesson_fp / lesson_total if lesson_total else 0.0
        bootstrap_values.append(round(clean_rate - lesson_rate, 6))
    sorted_bootstrap = sorted(bootstrap_values)
    sign_values: list[float] = []
    for swaps in product((False, True), repeat=4):
        clean_fp = clean_total = lesson_fp = lesson_total = 0
        for swap, family in zip(swaps, families):
            clean_values = clean["family_noise"][family]
            lesson_values = lesson["family_noise"][family]
            left, right = (lesson_values, clean_values) if swap else (clean_values, lesson_values)
            clean_fp += left[0]
            clean_total += left[1]
            lesson_fp += right[0]
            lesson_total += right[1]
        clean_rate = clean_fp / clean_total if clean_total else 0.0
        lesson_rate = lesson_fp / lesson_total if lesson_total else 0.0
        sign_values.append(round(clean_rate - lesson_rate, 6))
    observed = round(clean["fpr"] - lesson["fpr"], 6)
    return {
        "bootstrap_4_to_4": {
            "sample_count": 256,
            "values": bootstrap_values,
            "lower_2_5": sorted_bootstrap[6],
            "upper_97_5": sorted_bootstrap[249],
        },
        "sign_flip_2_to_4": {
            "sample_count": 16,
            "values": sign_values,
            "observed": observed,
            "one_sided_p": round(sum(value >= observed for value in sign_values) / 16, 6),
        },
    }


def evaluate_sealed(
    records: list[dict[str, Any]],
    fixtures: dict[str, dict[str, Any]],
    k_page: list[str],
    expected_scorer_digest: str,
    carrier_contract: dict[str, Any],
) -> dict[str, Any]:
    conditions = ("clean", "lesson-conditioned", "post-restart lesson-conditioned")
    failures = validate_records(records, fixtures, conditions, expected_scorer_digest)
    record_outcome = _record_outcome("sealed", failures, k_page=k_page)
    if record_outcome is not None:
        return record_outcome
    carrier_failures = _carrier_failures(records, fixtures, carrier_contract)
    if carrier_failures:
        return _outcome("sealed", "carrier_failure", carrier_failures, k_page=k_page)
    clean = _condition_metrics(records, fixtures, "clean")
    lesson = _condition_metrics(records, fixtures, "lesson-conditioned")
    restart = _condition_metrics(records, fixtures, "post-restart lesson-conditioned")
    metrics = {"clean": clean, "lesson-conditioned": lesson, "post-restart lesson-conditioned": restart}
    diagnostics = _diagnostics(clean, lesson)
    if any(condition["security_failure"] for condition in metrics.values()):
        return _outcome("sealed", "safety_failure", ["security.cross_task"], metrics=metrics, diagnostics=diagnostics, k_page=k_page)
    safety_failures: list[str] = []
    if any(condition["schema_valid_count"] != 12 for condition in metrics.values()):
        safety_failures.append("sealed.schema_validity")
    for name, condition in (("lesson", lesson), ("restart", restart)):
        if condition["material_recall"] != 1:
            safety_failures.append(f"sealed.{name}.material_recall")
        if condition["critical_codes"]:
            safety_failures.append(f"sealed.{name}.zero_critical")
    if safety_failures:
        return _outcome("sealed", "page_task_specific_failure", safety_failures, metrics=metrics, diagnostics=diagnostics, k_page=k_page)
    realized = [target for target in k_page if len(_stable_families(clean, target)) >= 2]
    if clean["fpr"] < 0.25 or len(realized) < 2:
        return _outcome(
            "sealed",
            "insufficient_sealed_headroom",
            ["sealed.clean_headroom"],
            metrics=metrics,
            diagnostics=diagnostics,
            k_page=k_page,
            realized_classes=realized,
        )

    lesson_transfers = {target: _transfer(clean, lesson, target) for target in k_page}
    lesson_positive = _positive_families(clean, lesson)
    lesson_failures: list[str] = []
    absolute = clean["fpr"] - lesson["fpr"]
    relative = absolute / clean["fpr"] if clean["fpr"] else 0
    if absolute < 0.20 or relative < 0.50:
        lesson_failures.append("sealed.lesson.fpr_reduction")
    if lesson["verdict_correct"] < 11:
        lesson_failures.append("sealed.lesson.verdict_accuracy")
    if lesson["success_count"] < 9:
        lesson_failures.append("sealed.lesson.task_success")
    if len(lesson_positive) < 3:
        lesson_failures.append("sealed.lesson.positive_families")
    if sum(item["passed"] for item in lesson_transfers.values()) < 2:
        lesson_failures.append("sealed.lesson.class_transfer")
    if lesson["success_count"] < clean["success_count"] or not _no_clean_success_lost(clean, lesson):
        lesson_failures.append("sealed.lesson.success_nonregression")
    if not _no_fixture_regression(clean, lesson):
        lesson_failures.append("sealed.lesson.fixture_medians")
    if lesson_failures:
        return _outcome(
            "sealed",
            "page_task_specific_failure",
            lesson_failures,
            metrics=metrics,
            diagnostics=diagnostics,
            k_page=k_page,
            lesson_transfers=lesson_transfers,
            lesson_positive_families=lesson_positive,
        )

    restart_transfers = {target: _transfer(clean, restart, target) for target in k_page}
    restart_positive = _positive_families(clean, restart)
    restart_failures: list[str] = []
    restart_absolute = clean["fpr"] - restart["fpr"]
    restart_relative = restart_absolute / clean["fpr"] if clean["fpr"] else 0
    if restart_absolute < 0.20 or restart_relative < 0.50:
        restart_failures.append("sealed.restart.fpr_reduction")
    if restart["fpr"] - lesson["fpr"] > 0.05:
        restart_failures.append("sealed.restart.fpr_drift")
    if restart["verdict_correct"] < 11 or lesson["verdict_correct"] - restart["verdict_correct"] > 1:
        restart_failures.append("sealed.restart.verdict_accuracy")
    if len(restart_positive) < 3:
        restart_failures.append("sealed.restart.positive_families")
    if sum(item["passed"] for item in restart_transfers.values()) < 2:
        restart_failures.append("sealed.restart.class_transfer")
    if restart["success_count"] < clean["success_count"]:
        restart_failures.append("sealed.restart.task_success")
    if any(
        restart["fixture_medians"][fixture] <= lesson_score - 5
        for fixture, lesson_score in lesson["fixture_medians"].items()
    ):
        restart_failures.append("sealed.restart.fixture_medians")
    if restart_failures:
        return _outcome(
            "sealed",
            "page_task_specific_failure",
            restart_failures,
            metrics=metrics,
            diagnostics=diagnostics,
            k_page=k_page,
            lesson_transfers=lesson_transfers,
            restart_transfers=restart_transfers,
            lesson_positive_families=lesson_positive,
            restart_positive_families=restart_positive,
        )
    return _outcome(
        "sealed",
        "page_validated",
        [],
        metrics=metrics,
        diagnostics=diagnostics,
        k_page=k_page,
        lesson_transfers=lesson_transfers,
        restart_transfers=restart_transfers,
        lesson_positive_families=lesson_positive,
        restart_positive_families=restart_positive,
    )
