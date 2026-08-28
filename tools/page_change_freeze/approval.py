"""D6 approval, immutable commit, executable, and one-shot live verification."""

from __future__ import annotations

import datetime as dt
import re
import stat
from pathlib import Path
from typing import Any, Callable, Optional
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from . import artifacts, manifest, recovery
from .contract import (
    APPROVAL_SCHEMA_VERSION,
    DECISION,
    EXECUTABLE_PATH,
    EXPERIMENT,
    FREEZE_MODULE_PATHS,
    FREEZE_VERIFIER_PATH,
    GIT_OBJECT_ID,
    HEX_SHA256,
    INVALIDATION_REPORT_PATH,
    RECOVERY_LEDGER_PATH,
    REPLACEMENT_DELTA_PATH,
    fail,
    load_json,
    load_json_bytes,
    normalized_path,
    require_keys,
    require_object,
    sha256_hex,
)

GITHUB_OWNER_LOGIN = "ivan-magda"
GITHUB_REPOSITORY_NAME = "swift-claw"
GITHUB_ISSUE_NUMBER = 118
GITHUB_WEB_ISSUE_URL = f"https://github.com/{GITHUB_OWNER_LOGIN}/{GITHUB_REPOSITORY_NAME}/issues/{GITHUB_ISSUE_NUMBER}"
GITHUB_API_ISSUE_URL = f"https://api.github.com/repos/{GITHUB_OWNER_LOGIN}/{GITHUB_REPOSITORY_NAME}/issues/{GITHUB_ISSUE_NUMBER}"
GITHUB_API_COMMENT_URL = f"https://api.github.com/repos/{GITHUB_OWNER_LOGIN}/{GITHUB_REPOSITORY_NAME}/issues/comments"
GITHUB_LOGIN = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$")
GITHUB_NODE_ID = re.compile(r"^[A-Za-z0-9_+=/-]+$")


def _positive(value: Any, *, location: str) -> int:
    if type(value) is not int or value <= 0:
        fail(f"{location} must be a positive integer")
    return value


def _node(value: Any, *, location: str) -> str:
    if not isinstance(value, str) or not GITHUB_NODE_ID.fullmatch(value):
        fail(f"{location} must be a non-empty GitHub node ID")
    return value


def _timestamp(value: Any, *, location: str) -> None:
    if not isinstance(value, str) or not value:
        fail(f"{location} must be a non-empty ISO-8601 timestamp")
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        fail(f"{location} must be a valid ISO-8601 timestamp")
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        fail(f"{location} must include a UTC offset")


def approval_statement(
    manifest_sha256: str,
    replacement_delta_sha256: str,
    recovery_ledger_sha256: str,
    invalidation_report_sha256: str,
    freeze_commit: str,
) -> str:
    return (
        f"D6 APPROVED: page manifest sha256={manifest_sha256} "
        f"replacement delta sha256={replacement_delta_sha256} "
        f"recovery ledger sha256={recovery_ledger_sha256} "
        f"invalidation report sha256={invalidation_report_sha256} "
        f"freeze_commit={freeze_commit}"
    )


def _artifact_binding(raw: Any, *, location: str, expected_path: str) -> tuple[str, str]:
    value = require_object(raw, location=location)
    require_keys(value, {"path", "sha256"}, location=location)
    path = normalized_path(value["path"], location=f"{location}.path")
    digest = value["sha256"]
    if path != expected_path:
        fail(f"{location}.path must be {expected_path}")
    if not isinstance(digest, str) or not HEX_SHA256.fullmatch(digest):
        fail(f"{location}.sha256 must be a lowercase SHA-256 digest")
    return path, digest


def parse_record(value: Any) -> dict[str, Any]:
    root = require_object(value, location="approval")
    require_keys(root, {"schema_version", "decision", "experiment", "repository",
                        "issue_number", "manifest", "replacement_delta", "recovery_ledger",
                        "invalidation_report", "freeze_commit", "comment"},
                 location="approval")
    if type(root["schema_version"]) is not int \
            or root["schema_version"] != APPROVAL_SCHEMA_VERSION or root["decision"] != DECISION \
            or root["experiment"] != EXPERIMENT:
        fail("approval must describe schema-2 D6 page-change")
    repository = require_object(root["repository"], location="approval.repository")
    require_keys(repository, {"owner", "name"}, location="approval.repository")
    if repository != {"owner": GITHUB_OWNER_LOGIN, "name": GITHUB_REPOSITORY_NAME}:
        fail("approval.repository must identify ivan-magda/swift-claw")
    if type(root["issue_number"]) is not int or root["issue_number"] != GITHUB_ISSUE_NUMBER:
        fail(f"approval.issue_number must be {GITHUB_ISSUE_NUMBER}")
    commit = root["freeze_commit"]
    if not isinstance(commit, str) or not GIT_OBJECT_ID.fullmatch(commit):
        fail("approval.freeze_commit must be a full lowercase Git object ID")
    manifest_record = require_object(root["manifest"], location="approval.manifest")
    require_keys(manifest_record, {"path", "sha256"}, location="approval.manifest")
    path = normalized_path(manifest_record["path"], location="approval.manifest.path")
    digest = manifest_record["sha256"]
    if not isinstance(digest, str) or not HEX_SHA256.fullmatch(digest):
        fail("approval.manifest.sha256 must be a lowercase SHA-256 digest")
    delta_path, delta_digest = _artifact_binding(
        root["replacement_delta"],
        location="approval.replacement_delta",
        expected_path=REPLACEMENT_DELTA_PATH,
    )
    ledger_path, ledger_digest = _artifact_binding(
        root["recovery_ledger"],
        location="approval.recovery_ledger",
        expected_path=RECOVERY_LEDGER_PATH,
    )
    report_path, report_digest = _artifact_binding(
        root["invalidation_report"],
        location="approval.invalidation_report",
        expected_path=INVALIDATION_REPORT_PATH,
    )
    comment = require_object(root["comment"], location="approval.comment")
    require_keys(comment, {"id", "node_id", "api_url", "html_url", "issue_url",
                           "author", "created_at", "updated_at", "body_sha256"},
                 location="approval.comment")
    comment_id = _positive(comment["id"], location="approval.comment.id")
    node_id = _node(comment["node_id"], location="approval.comment.node_id")
    if comment["api_url"] != f"{GITHUB_API_COMMENT_URL}/{comment_id}" \
            or comment["html_url"] != f"{GITHUB_WEB_ISSUE_URL}#issuecomment-{comment_id}" \
            or comment["issue_url"] != GITHUB_API_ISSUE_URL:
        fail("approval comment URLs must identify the exact issue comment")
    author = require_object(comment["author"], location="approval.comment.author")
    require_keys(author, {"login", "id", "node_id"}, location="approval.comment.author")
    login = author["login"]
    if not isinstance(login, str) or not GITHUB_LOGIN.fullmatch(login) or login != GITHUB_OWNER_LOGIN:
        fail(f"approval comment author must be the repository owner: {GITHUB_OWNER_LOGIN}")
    author_id = _positive(author["id"], location="approval.comment.author.id")
    author_node_id = _node(author["node_id"], location="approval.comment.author.node_id")
    _timestamp(comment["created_at"], location="approval.comment.created_at")
    _timestamp(comment["updated_at"], location="approval.comment.updated_at")
    if comment["updated_at"] != comment["created_at"]:
        fail("approval comment must be unedited: updated_at must equal created_at")
    body_digest = comment["body_sha256"]
    if not isinstance(body_digest, str) or not HEX_SHA256.fullmatch(body_digest):
        fail("approval.comment.body_sha256 must be a lowercase SHA-256 digest")
    return {
        "freeze_commit": commit, "manifest_path": path, "manifest_sha256": digest,
        "replacement_delta_path": delta_path, "replacement_delta_sha256": delta_digest,
        "recovery_ledger_path": ledger_path, "recovery_ledger_sha256": ledger_digest,
        "invalidation_report_path": report_path, "invalidation_report_sha256": report_digest,
        "comment_id": comment_id, "comment_node_id": node_id,
        "api_url": comment["api_url"], "html_url": comment["html_url"],
        "issue_url": comment["issue_url"], "author_login": login,
        "author_id": author_id, "author_node_id": author_node_id,
        "created_at": comment["created_at"], "updated_at": comment["updated_at"],
        "body_sha256": body_digest,
    }


def verify_record(value: Any, *, approval_body: bytes, manifest_path: str,
                  manifest_sha256: str) -> tuple[str, str]:
    record = parse_record(value)
    if record["manifest_path"] != manifest_path:
        fail(f"approval names the wrong manifest path: {record['manifest_path']}")
    if record["manifest_sha256"] != manifest_sha256:
        fail("approval names the wrong manifest digest")
    if sha256_hex(approval_body) != record["body_sha256"]:
        fail("approval comment body digest mismatch")
    try:
        body = approval_body.decode("utf-8")
    except UnicodeDecodeError:
        fail("approval comment body must be UTF-8")
    statement = approval_statement(
        manifest_sha256,
        record["replacement_delta_sha256"],
        record["recovery_ledger_sha256"],
        record["invalidation_report_sha256"],
        record["freeze_commit"],
    )
    if statement not in body.splitlines():
        fail(f"approval comment lacks the exact approval line: {statement}")
    return record["freeze_commit"], record["manifest_path"]


def prepare_binding(
    repo_root: Path,
    *,
    manifest_path: Path,
    approval: Any,
    approval_body: bytes,
) -> tuple[Path, str, dict[str, Any], bytes, dict[str, Any]]:
    root = repo_root.resolve(strict=True)
    relative = artifacts.repository_relative_path(root, manifest_path, location="manifest path")
    value, raw = load_json(manifest_path)
    verified = manifest.verify_structure(value, raw)
    digest = sha256_hex(raw)
    verify_record(approval, approval_body=approval_body,
                  manifest_path=relative, manifest_sha256=digest)
    record = parse_record(approval)
    recovery.verify_replacement_admission(
        root,
        verified,
        raw,
        replacement_delta_sha256=record["replacement_delta_sha256"],
        recovery_ledger_sha256=record["recovery_ledger_sha256"],
        invalidation_report_sha256=record["invalidation_report_sha256"],
    )
    return root, relative, verified, raw, record


def _default_http_get(url: str, headers: dict[str, str]) -> bytes:
    try:
        with urlopen(Request(url, headers=headers, method="GET"), timeout=30) as response:
            raw = response.read(4 * 1024 * 1024 + 1)
    except HTTPError as error:
        fail(f"GitHub returned HTTP {error.code} for issue comment lookup")
    except (URLError, OSError) as error:
        fail(f"cannot fetch GitHub issue comment: {error}")
    if len(raw) > 4 * 1024 * 1024:
        fail("GitHub issue comment response exceeds 4 MiB")
    return raw


def fetch_comment(comment_id: int, *, token: Optional[str] = None,
                  http_get: Optional[Callable[[str, dict[str, str]], bytes]] = None) -> dict[str, Any]:
    _positive(comment_id, location="GitHub comment ID")
    headers = {"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28",
               "User-Agent": "swift-claw-page-change-freeze-verifier"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    raw = (http_get or _default_http_get)(f"{GITHUB_API_COMMENT_URL}/{comment_id}", headers)
    return require_object(load_json_bytes(raw, location="GitHub issue comment response"),
                          location="GitHub issue comment response")


def verify_live_comment(value: Any, *, approval_body: bytes,
                        live_comment: dict[str, Any]) -> None:
    record = parse_record(value)
    if _positive(live_comment.get("id"), location="live comment.id") != record["comment_id"] \
            or _node(live_comment.get("node_id"), location="live comment.node_id") != record["comment_node_id"]:
        fail("live GitHub comment immutable ID does not match the approval record")
    for field, expected in (("url", record["api_url"]), ("html_url", record["html_url"]),
                            ("issue_url", record["issue_url"])):
        if live_comment.get(field) != expected:
            fail(f"live GitHub comment {field} does not match the approval record")
    author = require_object(live_comment.get("user"), location="live comment.user")
    observed_author = {"login": author.get("login"),
                       "id": _positive(author.get("id"), location="live comment.user.id"),
                       "node_id": _node(author.get("node_id"), location="live comment.user.node_id")}
    expected_author = {"login": record["author_login"], "id": record["author_id"],
                       "node_id": record["author_node_id"]}
    if observed_author != expected_author or live_comment.get("author_association") != "OWNER":
        fail("live GitHub comment owner identity does not match the approval record")
    if live_comment.get("created_at") != record["created_at"] \
            or live_comment.get("updated_at") != record["updated_at"]:
        fail("live GitHub comment timestamps do not match the approval record")
    if live_comment.get("updated_at") != live_comment.get("created_at"):
        fail("live GitHub approval comment has been edited")
    body = live_comment.get("body")
    if not isinstance(body, str) or body.encode() != approval_body \
            or sha256_hex(body.encode()) != record["body_sha256"]:
        fail("live GitHub comment body does not match the recorded approval bytes")


def _protected_record(value: dict[str, Any], path: str) -> dict[str, Any]:
    matches = [{key: item[key] for key in ("path", "bytes", "sha256")}
               for item in value["protected_artifacts"] if item["path"] == path]
    if len(matches) != 1:
        fail(f"manifest must contain one protected artifact record for {path}")
    return matches[0]


def _verifier_records(value: dict[str, Any]) -> list[dict[str, Any]]:
    return [{**_protected_record(value, path), "git_mode": "100644"}
            for path in sorted(FREEZE_MODULE_PATHS)]


def _executable_binding(repo_root: Path, value: dict[str, Any], path: Path) -> dict[str, Any]:
    try:
        mode = path.lstat().st_mode
    except OSError as error:
        fail(f"cannot stat running executable: {error}")
    if stat.S_ISLNK(mode):
        fail("running executable path may not be a symlink")
    relative = artifacts.repository_relative_path(repo_root, path,
                                                  location="running executable path")
    if relative != EXECUTABLE_PATH:
        fail(f"running executable path must be the frozen executable path: {EXECUTABLE_PATH}")
    expected = value["categories"]["executable"]["artifacts"][0]
    record = {key: expected[key] for key in ("path", "bytes", "sha256")}
    if artifacts.artifact(repo_root, relative) != record:
        fail("running executable bytes do not match the approved manifest record")
    artifacts.validate_executables(repo_root, value["categories"])
    return record


def verify_committed_replacement_delta(repo_root: Path, freeze_commit: str) -> None:
    expected = artifacts.artifact(repo_root, REPLACEMENT_DELTA_PATH)
    committed = artifacts.committed_blob(
        repo_root,
        commit=freeze_commit,
        path=REPLACEMENT_DELTA_PATH,
        mode="100644",
    )
    if len(committed) != expected["bytes"] or sha256_hex(committed) != expected["sha256"]:
        fail("approved commit has different replacement-delta bytes")


def verify_runtime_binding(repo_root: Path, *, manifest_path: Path,
                           expected_manifest_sha256: str, executable_path: Path,
                           package_description: Optional[dict[str, Any]] = None) -> dict[str, Any]:
    if not isinstance(expected_manifest_sha256, str) or not HEX_SHA256.fullmatch(expected_manifest_sha256):
        fail("expected manifest SHA-256 must be lowercase hexadecimal")
    value, raw = manifest.verify_path(repo_root, manifest_path,
                                      package_description=package_description,
                                      check_conformance=False)
    if sha256_hex(raw) != expected_manifest_sha256:
        fail("runtime received a manifest whose bytes do not match the approved SHA-256")
    executable = _executable_binding(repo_root.resolve(strict=True), value, executable_path)
    verifier_modules = _verifier_records(value)
    return {"schema_version": 1, "status": "verified", "manifest_sha256": expected_manifest_sha256,
            "verifier": next(item for item in verifier_modules if item["path"] == FREEZE_VERIFIER_PATH),
            "verifier_modules": verifier_modules,
            "executable": {**executable, "git_mode": "100755", "format": "mach-o-arm64"}}


def verify_live_freeze(repo_root: Path, *, manifest_path: Path, approval: Any,
                       approval_body: bytes, executable_path: Path,
                       token: Optional[str] = None,
                       http_get: Optional[Callable[[str, dict[str, str]], bytes]] = None,
                       now: Optional[Callable[[], dt.datetime]] = None,
                       package_description: Optional[dict[str, Any]] = None) -> dict[str, Any]:
    root, relative, value, raw, record = prepare_binding(
        repo_root,
        manifest_path=manifest_path,
        approval=approval,
        approval_body=approval_body,
    )
    digest = sha256_hex(raw)
    live = fetch_comment(record["comment_id"], token=token, http_get=http_get)
    verify_live_comment(approval, approval_body=approval_body, live_comment=live)
    manifest.verify_files(root, value, package_description=package_description)
    freeze_commit = record["freeze_commit"]
    artifacts.verify_commit_snapshot(root, freeze_commit=freeze_commit,
                                     manifest_path=relative, manifest_raw=raw, manifest=value)
    verify_committed_replacement_delta(root, freeze_commit)
    executable = _executable_binding(root, value, executable_path)
    verifier_modules = _verifier_records(value)
    clock = (now or (lambda: dt.datetime.now(dt.timezone.utc)))()
    if clock.tzinfo is None or clock.utcoffset() is None:
        fail("verification clock must return a timezone-aware datetime")
    verified_at = clock.astimezone(dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
    return {
        "schema_version": 1, "status": "verified", "verified_at": verified_at,
        "decision": DECISION, "experiment": EXPERIMENT,
        "manifest": {"path": relative, "sha256": digest},
        "verifier": next(item for item in verifier_modules if item["path"] == FREEZE_VERIFIER_PATH),
        "verifier_modules": verifier_modules, "freeze_commit": freeze_commit,
        "comment": {"id": record["comment_id"], "node_id": record["comment_node_id"],
                    "author": {"login": record["author_login"], "id": record["author_id"],
                               "node_id": record["author_node_id"]},
                    "created_at": record["created_at"], "updated_at": record["updated_at"],
                    "body_sha256": record["body_sha256"]},
        "executable": {**executable, "git_mode": "100755", "format": "mach-o-arm64"},
    }
