# Freeze test-intent map

This map follows [docs/TESTING.md §8.2](../../../docs/TESTING.md). A nearest test is named even
when it exercises the same public API; the explanation states why it does not kill the listed mutant.

| Risk | Production branch or seam | Nearest existing test | Unique mutant | Primary test |
| --- | --- | --- | --- | --- |
| Nondeterministic manifest bytes | `manifest.build` canonical output | `test_descriptor_requires_exact_categories_protocol_and_dependency_roles` never reorders valid input | descriptor iteration order leaks into bytes | `test_generation_is_canonical_and_input_order_independent` |
| Open descriptor schema | `manifest.parse_descriptor` | `test_generation_is_canonical_and_input_order_independent` uses only a valid descriptor | deleted category, wrong protocol digest, or missing dependency role is accepted | `test_descriptor_requires_exact_categories_protocol_and_dependency_roles` |
| Runtime semantics duplicated in freeze | descriptor → manifest content binding | `test_descriptor_requires_exact_categories_protocol_and_dependency_roles` mutates structure only | a changed descriptor value leaves digest unchanged, or a forged value bypasses protected descriptor | `test_descriptor_values_are_content_bound_without_duplicating_runtime_semantics` |
| Wrong protocol bytes | `artifacts.validate_protocol` | `test_descriptor_requires_exact_categories_protocol_and_dependency_roles` never mutates protocol file encoding | BOM/invalid UTF-8 reaches hash comparison or succeeds | `test_protocol_rejects_bom_and_invalid_utf8_before_hashing` |
| Unprotected file/module | repository closure seam | `test_file_verification_detects_changed_bytes_and_descriptor_drift` mutates an already listed file | omitted schema/verifier module or shadow source remains outside manifest | `test_full_artifact_and_verifier_module_closures_are_exact` |
| Importable bytes bypass source manifest | manifest membership for protected Python closures | `test_full_artifact_and_verifier_module_closures_are_exact` checks missing listed source only | pre-existing `.pyc` or native extension remains outside the protected source set | `test_python_closures_reject_unprotected_import_artifacts` |
| Incomplete compiler input closure | SwiftPM describe → categories | `test_real_swiftpm_description_matches_injected_shape` has no newly added transitive resource | newly transitive resource is omitted | `test_swiftpm_transitive_source_and_resource_closure_is_exact` |
| Non-runnable/wrong binary | file metadata and Mach-O header seam | `test_commit_snapshot_rejects_non_executable_and_symlink_git_modes` checks committed mode, not the working file/header | local mode, symlink, or CPU header is accepted | `test_executable_rejects_mode_symlink_and_wrong_architecture` |
| Post-generation edit | manifest records → working bytes | `test_structure_rejects_category_deletion_and_digest_mutation` never reads protected files | changed prompt bytes still verify | `test_file_verification_detects_changed_bytes_and_descriptor_drift` |
| Self-consistent malformed manifest | `manifest.verify_structure` | `test_descriptor_requires_exact_categories_protocol_and_dependency_roles` builds instead of verifying raw manifest bytes | deleted category or stale digest is accepted | `test_structure_rejects_category_deletion_and_digest_mutation` |
| False conformance preflight | protected executable seam | `test_isolated_bootstrap_uses_unique_package_and_stdlib` never interprets a runner receipt | nonzero exit, wrong passed count, wrong total, or noncanonical bytes authorize freeze | `test_protected_conformance_runner_must_emit_canonical_24_of_24` |
| Injected SwiftPM fixture drift | real SwiftPM process seam | `test_swiftpm_transitive_source_and_resource_closure_is_exact` uses an injected package description | actual describe misclassifies ClawEvaluation/claw-eval | `test_real_swiftpm_description_matches_injected_shape` |
| Wrong experiment topology | `run_order.derive` | `test_order_is_sensitive_to_external_final_manifest_digest` compares only changed order keys | counts, balance, A/B restart, synthesis, or barrier shape/order drift | `test_derives_exact_counterbalanced_attempts_and_barriers` |
| Run order independent of final digest | manifest SHA → derived keys | `test_derives_exact_counterbalanced_attempts_and_barriers` repeats one manifest digest | protected-byte change keeps order, or mismatched supplied SHA succeeds | `test_order_is_sensitive_to_external_final_manifest_digest` |
| Invalid frozen split inputs | splits contract → order blocks | `test_derives_exact_counterbalanced_attempts_and_barriers` uses valid split counts and identities | wrong count, split-prefixed identity, or duplicate fixture is accepted | `test_split_contract_identity_and_count_mutants_fail_closed` |
| Incomplete stored approval | `approval.verify_record` | `test_live_fetch_is_injected_and_identity_body_timestamp_mutants_fail` starts after stored-record parsing | wrong manifest/commit/body statement succeeds | `test_record_binds_unedited_owner_comment_body_manifest_and_commit` |
| Repository code before stored approval | stored D6 binding → SwiftPM/conformance execution | `test_record_binds_unedited_owner_comment_body_manifest_and_commit` calls no repository executable | invalid stored approval still runs the protected conformance program | `test_invalid_stored_approval_stops_before_repository_execution` |
| Repository code before live approval | live GitHub D6 verification → SwiftPM/conformance execution | `test_invalid_stored_approval_stops_before_repository_execution` stops before the HTTP seam | a valid stored record with a substituted live comment still runs protected repository code | `test_invalid_live_approval_stops_before_repository_execution` |
| Edited stored approval | approval timestamp/body seam | `test_record_binds_unedited_owner_comment_body_manifest_and_commit` uses immutable values | changed body or `updated_at != created_at` succeeds | `test_record_rejects_edited_timestamp_and_changed_body` |
| Substituted public comment | injected HTTP → live identity check | `test_record_binds_unedited_owner_comment_body_manifest_and_commit` does not observe a GitHub payload | issue/comment/owner/body/edit mutation succeeds | `test_live_fetch_is_injected_and_identity_body_timestamp_mutants_fail` |
| Git replacement attack | replace-disabled Git snapshot seam | `test_commit_snapshot_rejects_non_executable_and_symlink_git_modes` has no replacement ref | replacement commit changes approved view | `test_commit_snapshot_checks_modes_symlinks_and_disables_replace_refs` |
| Wrong committed object mode | `ls-tree` mode/type check | `test_executable_rejects_mode_symlink_and_wrong_architecture` never commits the mutant | `100644` executable or `120000` config succeeds | `test_commit_snapshot_rejects_non_executable_and_symlink_git_modes` |
| Wrong committed protected bytes | `cat-file` content binding | `test_commit_snapshot_rejects_non_executable_and_symlink_git_modes` mutates only Git modes | a committed protected blob differs from the bytes approved by the committed manifest | `test_commit_snapshot_rejects_protected_content_mismatch` |
| Incomplete local runtime binding | approved manifest → running executable/verifier closure | `test_live_freeze_is_one_shot_and_returns_canonical_machine_receipt` uses the canonical executable path and complete module set | alias binary or omitted verifier module succeeds | `test_runtime_binding_checks_digest_path_bytes_and_all_verifier_modules` |
| Repeated remote polling / incomplete receipt | one-shot live preflight seam | `test_live_fetch_is_injected_and_identity_body_timestamp_mutants_fail` validates payload identity but not total fetch count or receipt completeness | multiple HTTP calls or missing receipt binding succeeds | `test_live_freeze_is_one_shot_and_returns_canonical_machine_receipt` |
| Misleading command contract | `cli.parser` public names | `test_isolated_bootstrap_uses_unique_package_and_stdlib` proves loading but not command names | old ambiguous approval name returns | `test_cli_names_offline_live_and_local_runtime_checks_honestly` |
| CLI entry-point wiring | isolated `freeze.py` → `generate` handler | `test_cli_names_offline_live_and_local_runtime_checks_honestly` checks parser text only | the CLI parses `generate` but does not invoke its handler or persist canonical output | `test_cli_generate_runs_through_isolated_entry_point` |
| Unsafe manifest output target | `generate` output containment and link guard | `test_cli_generate_runs_through_isolated_entry_point` uses a new in-repository leaf | an outside path or existing symlink is overwritten | `test_cli_generate_rejects_outside_and_symlink_outputs` |
| Ambient import/bytecode substitution | isolated bootstrap import seam | `test_cli_names_offline_live_and_local_runtime_checks_honestly` imports the package normally | ambient `tools`, sibling shadow, or cached bytecode wins | `test_isolated_bootstrap_uses_unique_package_and_stdlib` |
| Symlinked verifier module | isolated bootstrap preflight | `test_isolated_bootstrap_uses_unique_package_and_stdlib` uses regular source files | a symlinked protected source executes before manifest verification | `test_isolated_bootstrap_rejects_symlinked_source_before_import` |
| Verifier import creates unprotected bytes | isolated bootstrap postflight | `test_isolated_bootstrap_rejects_symlinked_source_before_import` stops at the preflight | a verifier module creates an import artifact and raises before the postflight | `test_isolated_bootstrap_rechecks_closure_when_import_fails` |
| Noncanonical receipt transport | `cli.emit_receipt` file/stdout seam | `test_live_freeze_is_one_shot_and_returns_canonical_machine_receipt` inspects the receipt object, not emitted bytes | persisted receipt omits the canonical LF required by Swift or stdout differs from it | `test_receipt_file_and_stdout_share_one_canonical_lf` |
| Duplicate JSON keys become ambiguous | `contract.load_json_bytes` object-pairs seam | `test_structure_rejects_category_deletion_and_digest_mutation` starts from an already decoded object | the last duplicate key silently replaces the first | `test_json_loader_rejects_duplicate_object_keys` |
| Repository-relative path traversal | `contract.normalized_path` lexical guard | `test_full_artifact_and_verifier_module_closures_are_exact` uses only normalized descriptor paths | a parent component escapes the protected repository namespace | `test_normalized_path_rejects_parent_traversal` |

## Keep/delete/reuse decision

Kept tests cover only freeze-owned behavior: content binding, exact closure, deterministic order, D6
approval, Git modes/types, executable binding, and isolated CLI receipts.

Deleted from the former monolithic suite:

- canary materialization and the page canonical vector (owned by benchmark and Swift);
- runtime configuration field/value validation (owned by `EvaluationRuntimeConfiguration`);
- fixture/scorer/linter semantic classification (owned by benchmark tests and protected 24-case
  conformance).

The shared `FreezeRepository` fixture reuses production constants, `manifest.build`,
`run_order.RUN_ORDER_VALUES`, strict canonical encoding, and the production descriptor parser. Its
executable scripts are boundary stubs only; they do not reimplement production scoring or ordering.
The final provisional actual-repository generation/verification is the integration check against the
real protected wrappers and source graph.
