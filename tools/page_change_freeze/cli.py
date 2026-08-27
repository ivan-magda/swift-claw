"""Command-line interface for the page-change freeze package."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import sys
import tempfile
from typing import Any, Optional

from . import approval, artifacts, manifest, run_order
from .contract import (
    FREEZE_VERIFIER_PATH,
    MANIFEST_DESCRIPTOR_PATH,
    FreezeError,
    canonical_json_bytes,
    canonical_json_line_bytes,
    fail,
    load_json,
    normalized_path,
    sha256_hex,
)


def _output(repo_root: Path, path: Path) -> tuple[Path, str]:
    root = repo_root.resolve(strict=True)
    try:
        parent = path.parent.resolve(strict=True)
    except OSError as error:
        fail(f"cannot resolve output parent: {error}")
    if parent != root and root not in parent.parents:
        fail(f"output is outside the repository root: {path}")
    if path.exists() and path.is_symlink():
        fail(f"output may not be a symlink: {path}")
    relative = normalized_path((parent.relative_to(root) / path.name).as_posix(),
                               location="output path")
    return root / relative, relative


def atomic_write(path: Path, data: bytes) -> None:
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_name, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    except BaseException:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise


def emit_receipt(receipt: dict[str, Any], *, output_path: Optional[Path] = None,
                 stream: Optional[Any] = None) -> bytes:
    raw = canonical_json_line_bytes(receipt)
    if output_path is not None:
        if output_path.exists() and output_path.is_symlink():
            fail(f"receipt output may not be a symlink: {output_path}")
        try:
            output_path.parent.resolve(strict=True)
        except OSError as error:
            fail(f"cannot resolve receipt output parent: {error}")
        atomic_write(output_path, raw)
    (stream or sys.stdout.buffer).write(raw)
    return raw


def command_generate(arguments: argparse.Namespace) -> int:
    root = arguments.repo_root.resolve(strict=True)
    descriptor, raw_descriptor = load_json(arguments.descriptor)
    relative = artifacts.repository_relative_path(root, arguments.descriptor,
                                                  location="descriptor path")
    if relative != MANIFEST_DESCRIPTOR_PATH:
        fail(f"descriptor path must be the frozen canonical path: {MANIFEST_DESCRIPTOR_PATH}")
    if canonical_json_line_bytes(descriptor) != raw_descriptor:
        fail("descriptor must use canonical JSON bytes with exactly one trailing LF")
    value = manifest.build(root, descriptor)
    raw = canonical_json_bytes(value)
    manifest.verify_structure(value, raw)
    output, output_relative = _output(root, arguments.output)
    if any(item["path"] == output_relative for item in value["protected_artifacts"]):
        fail("the manifest cannot list itself as a protected artifact")
    if output_relative == relative:
        fail("the manifest output cannot overwrite its descriptor")
    atomic_write(output, raw)
    print(f"manifest_path={output_relative}")
    print(f"manifest_sha256={sha256_hex(raw)}")
    return 0


def command_verify(arguments: argparse.Namespace) -> int:
    root = arguments.repo_root.resolve(strict=True)
    relative = artifacts.repository_relative_path(root, arguments.manifest,
                                                  location="manifest path")
    _, raw = manifest.verify_path(root, arguments.manifest)
    print(f"manifest_path={relative}")
    print(f"manifest_sha256={sha256_hex(raw)}")
    print("protected_artifacts=verified")
    return 0


def _approval_inputs(arguments: argparse.Namespace) -> tuple[Path, str, dict[str, Any], bytes, str]:
    record, record_raw = load_json(arguments.approval)
    if canonical_json_bytes(record) != record_raw:
        fail("approval record bytes are not canonical JSON")
    try:
        body = arguments.approval_body.read_bytes()
    except OSError as error:
        fail(f"cannot read approval body: {error}")
    root, relative, value, raw, parsed = approval.prepare_binding(
        arguments.repo_root,
        manifest_path=arguments.manifest,
        approval=record,
        approval_body=body,
    )
    manifest.verify_files(root, value)
    commit = parsed["freeze_commit"]
    artifacts.verify_commit_snapshot(root, freeze_commit=commit, manifest_path=relative,
                                     manifest_raw=raw, manifest=value)
    return root, relative, value, raw, commit


def command_verify_record(arguments: argparse.Namespace) -> int:
    _, relative, _, raw, commit = _approval_inputs(arguments)
    print(f"manifest_path={relative}")
    print(f"manifest_sha256={sha256_hex(raw)}")
    print(f"freeze_commit={commit}")
    print("approval_record=consistent")
    return 0


def command_verify_live(arguments: argparse.Namespace) -> int:
    record, raw = load_json(arguments.approval)
    if canonical_json_bytes(record) != raw:
        fail("approval record bytes are not canonical JSON")
    try:
        body = arguments.approval_body.read_bytes()
    except OSError as error:
        fail(f"cannot read approval body: {error}")
    token = os.environ.get(arguments.github_token_env) if arguments.github_token_env else None
    receipt = approval.verify_live_freeze(
        arguments.repo_root, manifest_path=arguments.manifest, approval=record,
        approval_body=body, executable_path=arguments.executable, token=token,
    )
    emit_receipt(receipt, output_path=arguments.receipt_output)
    return 0


def command_verify_runtime(arguments: argparse.Namespace) -> int:
    receipt = approval.verify_runtime_binding(
        arguments.repo_root, manifest_path=arguments.manifest,
        expected_manifest_sha256=arguments.manifest_sha256,
        executable_path=arguments.executable,
    )
    sys.stdout.buffer.write(canonical_json_bytes(receipt) + b"\n")
    return 0


def command_run_order(arguments: argparse.Namespace) -> int:
    value, raw = load_json(arguments.manifest)
    verified = manifest.verify_structure(value, raw)
    digest = sha256_hex(raw)
    if digest != arguments.manifest_sha256:
        fail("manifest bytes do not match --manifest-sha256")
    sys.stdout.buffer.write(canonical_json_bytes(run_order.derive(verified, digest)) + b"\n")
    return 0


def _approval_arguments(command: argparse.ArgumentParser) -> None:
    command.add_argument("--repo-root", type=Path, required=True)
    command.add_argument("--manifest", type=Path, required=True)
    command.add_argument("--approval", type=Path, required=True)
    command.add_argument("--approval-body", type=Path, required=True)


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description="Generate and verify the page-change D6 manifest.")
    commands = root.add_subparsers(dest="command", required=True)
    generate = commands.add_parser("generate", help="generate a canonical D6 page manifest")
    generate.add_argument("--repo-root", type=Path, required=True)
    generate.add_argument("--descriptor", type=Path, required=True)
    generate.add_argument("--output", type=Path, required=True)
    generate.set_defaults(handler=command_generate)
    verify = commands.add_parser("verify", help="verify canonical bytes and protected files")
    verify.add_argument("--repo-root", type=Path, required=True)
    verify.add_argument("--manifest", type=Path, required=True)
    verify.set_defaults(handler=command_verify)
    record = commands.add_parser("verify-record-consistency",
                                 help="check stored approval bytes and commit without GitHub")
    _approval_arguments(record)
    record.set_defaults(handler=command_verify_record)
    live = commands.add_parser("verify-live-freeze",
                               help="one-shot live approval and complete freeze preflight")
    _approval_arguments(live)
    live.add_argument("--executable", type=Path, required=True)
    live.add_argument("--receipt-output", type=Path)
    live.add_argument("--github-token-env", default="GITHUB_TOKEN")
    live.set_defaults(handler=command_verify_live)
    runtime = commands.add_parser("verify-runtime-binding",
                                  help="verify only local immutable manifest/executable bindings")
    runtime.add_argument("--repo-root", type=Path, required=True)
    runtime.add_argument("--manifest", type=Path, required=True)
    runtime.add_argument("--manifest-sha256", required=True)
    runtime.add_argument("--executable", type=Path, required=True)
    runtime.set_defaults(handler=command_verify_runtime)
    order = commands.add_parser("derive-run-order", help="derive frozen order from manifest SHA-256")
    order.add_argument("--manifest", type=Path, required=True)
    order.add_argument("--manifest-sha256", required=True)
    order.set_defaults(handler=command_run_order)
    return root


def main() -> int:
    try:
        arguments = parser().parse_args()
        return arguments.handler(arguments)
    except FreezeError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
