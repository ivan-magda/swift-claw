# Security Policy

`clawd` holds your Telegram credentials, LLM keys, and personal data, and it executes
tools on your behalf. Security reports take priority over feature work.

## Reporting a vulnerability

Report privately through GitHub: **Security → [Report a vulnerability](../../security/advisories/new)**.
Do not open a public issue for anything exploitable.

Include the affected version or commit, reproduction steps, and the impact you see.
You will get an acknowledgment within 7 days and a status update when the fix lands
or the report is declined, with reasoning either way.

## Scope

Reports in these areas matter most:

- Bypassing the Telegram allowlist (getting a conversation, or any action, without being allowlisted).
- Bypassing the approval fabric: a forged or third-party callback that approves an action, or a consequential action that runs without approval.
- Escaping the code-execution sandbox through clawd's integration (host paths, network, or secrets reachable from guest code without the documented opt-ins).
- Defeating the exfiltration gate or the SSRF blocklist.
- Secret exposure: plaintext at rest where encryption is promised, or secrets surviving log redaction.
- Prompt injection that crosses a policy enforced in code. Model output that is merely odd or unhelpful is not a vulnerability.

Vulnerabilities in upstream dependencies belong upstream; open a regular issue here
asking for the version bump.

## Supported versions

The latest release and `main`.
