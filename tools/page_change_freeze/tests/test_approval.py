from __future__ import annotations

import copy
import datetime as dt
from pathlib import Path
import unittest
from unittest import mock

from tools.page_change_freeze import approval, artifacts, contract
from tools.page_change_freeze.tests.support import FreezeRepository


class ApprovalTests(unittest.TestCase):
    def setUp(self) -> None:
        self.repo = FreezeRepository()

    def tearDown(self) -> None:
        self.repo.cleanup()

    def _approval(self, *, digest: str, commit: str, body: bytes) -> dict:
        comment_id = 5_423_356_186
        return {
            "schema_version": contract.APPROVAL_SCHEMA_VERSION,
            "decision": contract.DECISION, "experiment": contract.EXPERIMENT,
            "repository": {"owner": approval.GITHUB_OWNER_LOGIN,
                           "name": approval.GITHUB_REPOSITORY_NAME},
            "issue_number": approval.GITHUB_ISSUE_NUMBER,
            "manifest": {"path": f"{contract.PAGE_ROOT}/freeze/page-manifest.json",
                         "sha256": digest},
            "replacement_delta": {
                "path": contract.REPLACEMENT_DELTA_PATH,
                "sha256": contract.sha256_hex(
                    (self.repo.root / contract.REPLACEMENT_DELTA_PATH).read_bytes()
                ),
            },
            "recovery_ledger": {
                "path": contract.RECOVERY_LEDGER_PATH,
                "sha256": contract.sha256_hex(
                    (self.repo.root / contract.RECOVERY_LEDGER_PATH).read_bytes()
                ),
            },
            "invalidation_report": {
                "path": contract.INVALIDATION_REPORT_PATH,
                "sha256": contract.INVALIDATION_REPORT_SHA256,
            },
            "freeze_commit": commit,
            "comment": {
                "id": comment_id, "node_id": "IC_kwDOExample",
                "api_url": f"{approval.GITHUB_API_COMMENT_URL}/{comment_id}",
                "html_url": f"{approval.GITHUB_WEB_ISSUE_URL}#issuecomment-{comment_id}",
                "issue_url": approval.GITHUB_API_ISSUE_URL,
                "author": {"login": approval.GITHUB_OWNER_LOGIN, "id": 12_345,
                           "node_id": "MDQ6VXNlcjEyMzQ1"},
                "created_at": "2026-08-26T12:00:00Z",
                "updated_at": "2026-08-26T12:00:00Z",
                "body_sha256": contract.sha256_hex(body),
            },
        }

    def _body(self, digest: str, commit: str) -> bytes:
        return (
            approval.approval_statement(
                digest,
                contract.sha256_hex(
                    (self.repo.root / contract.REPLACEMENT_DELTA_PATH).read_bytes()
                ),
                contract.sha256_hex(
                    (self.repo.root / contract.RECOVERY_LEDGER_PATH).read_bytes()
                ),
                contract.INVALIDATION_REPORT_SHA256,
                commit,
            )
            + "\n"
        ).encode()

    def _live_comment(self, value: dict, body: bytes) -> dict:
        comment = value["comment"]
        return {
            "id": comment["id"], "node_id": comment["node_id"],
            "url": comment["api_url"], "html_url": comment["html_url"],
            "issue_url": comment["issue_url"], "user": copy.deepcopy(comment["author"]),
            "author_association": "OWNER", "created_at": comment["created_at"],
            "updated_at": comment["updated_at"], "body": body.decode(),
        }

    def _manifest_with_marker_runner(self) -> tuple[dict, bytes, Path, Path]:
        marker = self.repo.root / "conformance-executed"
        runner = self.repo.root / contract.CONFORMANCE_EXECUTABLE_PATH
        runner.write_text(
            f"#!/bin/sh\ntouch {str(marker)!r}\nprintf '{{\"passed\":24,\"total\":24}}\\n'\n"
        )
        runner.chmod(0o755)
        value = self.repo.make_manifest()
        marker.unlink()
        raw = contract.canonical_json_bytes(value)
        manifest_path = self.repo.root / f"{contract.PAGE_ROOT}/freeze/page-manifest.json"
        manifest_path.write_bytes(raw)
        return value, raw, manifest_path, marker

    def test_record_binds_unedited_owner_comment_body_manifest_and_commit(self) -> None:
        # given
        digest, commit = "a" * 64, "b" * 40
        body = self._body(digest, commit)
        value = self._approval(digest=digest, commit=commit, body=body)

        # when
        actual = approval.verify_record(
            value, approval_body=body,
            manifest_path=f"{contract.PAGE_ROOT}/freeze/page-manifest.json",
            manifest_sha256=digest,
        )

        # then
        self.assertEqual(actual, (commit, f"{contract.PAGE_ROOT}/freeze/page-manifest.json"))

        mutations = []
        wrong_path = copy.deepcopy(value)
        wrong_path["manifest"]["path"] = f"{contract.PAGE_ROOT}/freeze/other.json"
        mutations.append((wrong_path, body, "wrong manifest path"))
        wrong_digest = copy.deepcopy(value)
        wrong_digest["manifest"]["sha256"] = "c" * 64
        mutations.append((wrong_digest, body, "wrong manifest digest"))
        for field in ("replacement_delta", "recovery_ledger", "invalidation_report"):
            wrong_binding = copy.deepcopy(value)
            wrong_binding[field]["sha256"] = "c" * 64
            mutations.append((wrong_binding, body, "exact approval line"))
        wrong_statement_body = b"D6 is not approved\n"
        wrong_statement = self._approval(
            digest=digest,
            commit=commit,
            body=wrong_statement_body,
        )
        mutations.append((wrong_statement, wrong_statement_body, "exact approval line"))
        wrong_commit = copy.deepcopy(value)
        wrong_commit["freeze_commit"] = "d" * 40
        mutations.append((wrong_commit, body, "exact approval line"))
        for candidate, candidate_body, message in mutations:
            with self.subTest(message=message), self.assertRaisesRegex(
                contract.FreezeError,
                message,
            ):
                approval.verify_record(
                    candidate,
                    approval_body=candidate_body,
                    manifest_path=f"{contract.PAGE_ROOT}/freeze/page-manifest.json",
                    manifest_sha256=digest,
                )

    def test_record_rejects_edited_timestamp_and_changed_body(self) -> None:
        # given
        digest, commit = "a" * 64, "b" * 40
        body = self._body(digest, commit)
        for mutation, message in (("timestamp", "must be unedited"), ("body", "body digest")):
            with self.subTest(mutation=mutation):
                value = self._approval(digest=digest, commit=commit, body=body)
                observed = body
                if mutation == "timestamp":
                    value["comment"]["updated_at"] = "2026-08-26T12:01:00Z"
                else:
                    observed += b"edited"

                # when
                with self.assertRaises(contract.FreezeError) as raised:
                    approval.verify_record(
                        value, approval_body=observed,
                        manifest_path=f"{contract.PAGE_ROOT}/freeze/page-manifest.json",
                        manifest_sha256=digest,
                    )

                # then
                self.assertRegex(str(raised.exception), message)

    def test_live_fetch_is_injected_and_identity_body_timestamp_mutants_fail(self) -> None:
        # given
        digest, commit = "a" * 64, "b" * 40
        body = self._body(digest, commit)
        value = self._approval(digest=digest, commit=commit, body=body)
        baseline = self._live_comment(value, body)
        observed: dict[str, object] = {}

        def http_get(url: str, headers: dict[str, str]) -> bytes:
            observed.update(url=url, headers=headers)
            return contract.canonical_json_bytes(baseline)

        # when
        fetched = approval.fetch_comment(value["comment"]["id"], token="token", http_get=http_get)
        approval.verify_live_comment(value, approval_body=body, live_comment=fetched)

        # then
        self.assertEqual(observed["url"], value["comment"]["api_url"])
        self.assertEqual(observed["headers"]["Authorization"], "Bearer token")  # type: ignore[index]

        mutations = {
            "issue": (lambda item: item.__setitem__(
                "issue_url", "https://api.github.com/repos/x/y/issues/1"
            ), "issue_url does not match"),
            "comment": (lambda item: item.__setitem__("node_id", "IC_other"), "immutable ID"),
            "owner": (lambda item: item["user"].__setitem__("id", 999), "owner identity"),
            "body": (lambda item: item.__setitem__("body", "changed"), "body does not match"),
            "edited": (lambda item: item.__setitem__(
                "updated_at", "2026-08-26T12:01:00Z"
            ), "timestamps do not match"),
        }
        for name, (mutate, message) in mutations.items():
            with self.subTest(name=name):
                candidate = copy.deepcopy(baseline)
                mutate(candidate)

                # when
                with self.assertRaises(contract.FreezeError) as raised:
                    approval.verify_live_comment(value, approval_body=body, live_comment=candidate)

                # then
                self.assertRegex(str(raised.exception), message)

    def test_commit_snapshot_checks_modes_symlinks_and_disables_replace_refs(self) -> None:
        # given
        value, raw, path, commit = self.repo.committed_manifest()
        self.repo.write(contract.TASK_PROMPT_PATH, b"replacement\n")
        self.repo.git("add", contract.TASK_PROMPT_PATH)
        self.repo.git("commit", "-qm", "replacement")
        replacement = self.repo.git("rev-parse", "HEAD").strip()
        self.repo.git("replace", commit, replacement)

        # when
        result = artifacts.verify_commit_snapshot(
            self.repo.root, freeze_commit=commit,
            manifest_path=path, manifest_raw=raw, manifest=value,
        )

        # then
        self.assertIsNone(result)

    def test_commit_snapshot_rejects_non_executable_and_symlink_git_modes(self) -> None:
        # given
        for mutation, message in (("mode", "expected 100755 blob"),
                                  ("symlink", "observed 120000 blob")):
            with self.subTest(mutation=mutation):
                candidate = FreezeRepository()
                try:
                    value = candidate.make_manifest()
                    raw = contract.canonical_json_bytes(value)
                    path = f"{contract.PAGE_ROOT}/freeze/page-manifest.json"
                    candidate.write(path, raw)
                    target_path = contract.EXECUTABLE_PATH if mutation == "mode" \
                        else contract.RUNTIME_CONFIGURATION_PATH
                    target = candidate.root / target_path
                    if mutation == "mode":
                        target.chmod(0o644)
                    else:
                        link_target = target.with_name("target.json")
                        target.rename(link_target)
                        target.symlink_to(link_target)
                    candidate.init_git()
                    candidate.git("add", ".")
                    candidate.git("commit", "-qm", mutation)
                    commit = candidate.git("rev-parse", "HEAD").strip()

                    # when
                    with self.assertRaises(contract.FreezeError) as raised:
                        artifacts.verify_commit_snapshot(candidate.root, freeze_commit=commit,
                                                         manifest_path=path, manifest_raw=raw,
                                                         manifest=value)

                    # then
                    self.assertRegex(str(raised.exception), message)
                finally:
                    candidate.cleanup()

    def test_commit_snapshot_rejects_protected_content_mismatch(self) -> None:
        # given
        self.repo.init_git()
        self.repo.git("add", ".")
        self.repo.git("commit", "-qm", "baseline")
        self.repo.write(contract.TASK_PROMPT_PATH, b"changed but not committed\n")
        value = self.repo.make_manifest()
        raw = contract.canonical_json_bytes(value)
        relative = f"{contract.PAGE_ROOT}/freeze/page-manifest.json"
        self.repo.write(relative, raw)
        self.repo.git("add", relative)
        self.repo.git("commit", "-qm", "manifest only")
        commit = self.repo.git("rev-parse", "HEAD").strip()

        # when
        with self.assertRaises(contract.FreezeError) as raised:
            artifacts.verify_commit_snapshot(
                self.repo.root,
                freeze_commit=commit,
                manifest_path=relative,
                manifest_raw=raw,
                manifest=value,
            )

        # then
        self.assertRegex(str(raised.exception), "different protected bytes")
        self.repo.write(contract.REPLACEMENT_DELTA_PATH, b'{"changed":true}')
        with self.assertRaisesRegex(contract.FreezeError, "different replacement-delta bytes"):
            approval.verify_committed_replacement_delta(self.repo.root, commit)

    def test_runtime_binding_checks_digest_path_bytes_and_all_verifier_modules(self) -> None:
        # given
        value = self.repo.make_manifest()
        raw = contract.canonical_json_bytes(value)
        path = self.repo.root / f"{contract.PAGE_ROOT}/freeze/page-manifest.json"
        path.write_bytes(raw)

        # when
        receipt = approval.verify_runtime_binding(
            self.repo.root, manifest_path=path,
            expected_manifest_sha256=contract.sha256_hex(raw),
            executable_path=self.repo.root / contract.EXECUTABLE_PATH,
            package_description=self.repo.package_description,
        )

        # then
        self.assertEqual({item["path"] for item in receipt["verifier_modules"]},
                         set(contract.FREEZE_MODULE_PATHS))
        with self.assertRaisesRegex(contract.FreezeError, "bytes do not match"):
            approval.verify_runtime_binding(
                self.repo.root,
                manifest_path=path,
                expected_manifest_sha256="f" * 64,
                executable_path=self.repo.root / contract.EXECUTABLE_PATH,
                package_description=self.repo.package_description,
            )
        alias = self.repo.root / f"{contract.PAGE_ROOT}/artifacts/alias"
        alias.write_bytes((self.repo.root / contract.EXECUTABLE_PATH).read_bytes())
        alias.chmod(0o755)
        with self.assertRaisesRegex(contract.FreezeError, "frozen executable path"):
            approval.verify_runtime_binding(
                self.repo.root, manifest_path=path,
                expected_manifest_sha256=contract.sha256_hex(raw), executable_path=alias,
                package_description=self.repo.package_description,
            )

    def test_invalid_stored_approval_stops_before_repository_execution(self) -> None:
        # given
        _, raw, manifest_path, marker = self._manifest_with_marker_runner()
        digest = contract.sha256_hex(raw)
        body = b"D6 is not approved\n"
        record = self._approval(digest=digest, commit="b" * 40, body=body)
        http_calls = 0

        def http_get(_url: str, _headers: dict[str, str]) -> bytes:
            nonlocal http_calls
            http_calls += 1
            return b"{}"

        # when
        with self.assertRaisesRegex(contract.FreezeError, "exact approval line"):
            approval.verify_live_freeze(
                self.repo.root,
                manifest_path=manifest_path,
                approval=record,
                approval_body=body,
                executable_path=self.repo.root / contract.EXECUTABLE_PATH,
                http_get=http_get,
                package_description=self.repo.package_description,
            )

        # then
        self.assertFalse(marker.exists())
        self.assertEqual(http_calls, 0)

    def test_invalid_live_approval_stops_before_repository_execution(self) -> None:
        # given
        _, raw, manifest_path, marker = self._manifest_with_marker_runner()
        digest = contract.sha256_hex(raw)
        commit = "b" * 40
        body = self._body(digest, commit)
        record = self._approval(digest=digest, commit=commit, body=body)
        live = self._live_comment(record, body)
        live["body"] = "substituted live comment"

        # when
        with mock.patch.object(
            approval.recovery,
            "verify_replacement_admission",
            return_value={"status": "verified"},
        ), self.assertRaisesRegex(contract.FreezeError, "body does not match"):
            approval.verify_live_freeze(
                self.repo.root,
                manifest_path=manifest_path,
                approval=record,
                approval_body=body,
                executable_path=self.repo.root / contract.EXECUTABLE_PATH,
                http_get=lambda _url, _headers: contract.canonical_json_bytes(live),
                package_description=self.repo.package_description,
            )

        # then
        self.assertFalse(marker.exists())

    def test_live_freeze_is_one_shot_and_returns_canonical_machine_receipt(self) -> None:
        # given
        value, raw, relative, commit = self.repo.committed_manifest()
        digest = contract.sha256_hex(raw)
        body = self._body(digest, commit)
        record = self._approval(digest=digest, commit=commit, body=body)
        live = self._live_comment(record, body)
        calls = 0

        def http_get(_url: str, _headers: dict[str, str]) -> bytes:
            nonlocal calls
            calls += 1
            return contract.canonical_json_bytes(live)

        # when
        with mock.patch.object(
            approval.recovery,
            "verify_replacement_admission",
            return_value={"status": "verified"},
        ) as verify_admission:
            receipt = approval.verify_live_freeze(
                self.repo.root, manifest_path=self.repo.root / relative, approval=record,
                approval_body=body, executable_path=self.repo.root / contract.EXECUTABLE_PATH,
                http_get=http_get,
                now=lambda: dt.datetime(2026, 8, 26, 15, 30, tzinfo=dt.timezone.utc),
                package_description=self.repo.package_description,
            )

        # then
        verify_admission.assert_called_once()
        self.assertEqual(calls, 1)
        self.assertEqual(receipt["verified_at"], "2026-08-26T15:30:00Z")
        self.assertEqual(receipt["manifest"]["sha256"], digest)
        self.assertEqual(len(receipt["verifier_modules"]), len(contract.FREEZE_MODULE_PATHS))
        self.assertEqual(receipt["executable"]["sha256"],
                         value["categories"]["executable"]["artifacts"][0]["sha256"])
        self.assertEqual(set(receipt), {
            "schema_version", "status", "verified_at", "decision", "experiment",
            "manifest", "verifier", "verifier_modules", "freeze_commit", "comment",
            "executable",
        })
        self.assertEqual(set(receipt["comment"]), {
            "id", "node_id", "author", "created_at", "updated_at", "body_sha256",
        })


if __name__ == "__main__":
    unittest.main()
