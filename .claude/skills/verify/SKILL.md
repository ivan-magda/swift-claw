---
name: verify
description: Verify clawd CLI or configuration changes with isolated doctor probes that need no real Telegram or LLM credentials.
---

# Verify clawd at the CLI surface

Run from the repository root. Build with `swift build`; use `./.build/debug/clawd`.
These probes supplement the root instructions' lint/build/test gate.

## Isolated offline probe

Use a clean environment and a disposable state root. Changing only `CLAW_STATE_ROOT` still
inherits real credentials and enabled MCP/Coder/sandbox configuration. Do not source the
owner's `clawd.env` or start `clawd run` for this probe.

This example requires Python 3, bounds the invocation, retains its actual exit code,
and removes its scratch root. Add only the env keys needed for the case under test:

```bash
python3 - <<'PYTHON'
import json
import os
import subprocess
import tempfile

with tempfile.TemporaryDirectory(prefix="clawd-verify-") as state_root:
    environment = {
        "PATH": os.environ["PATH"],
        "CLAW_STATE_ROOT": state_root,
        "CLAW_LLM_BASE_URL": "http://localhost:9/v1",
        "CLAW_LLM_MODEL": "test-model",
    }
    result = subprocess.run(
        ["./.build/debug/clawd", "doctor", "--check-config", "--json"],
        env=environment, capture_output=True, text=True, timeout=30,
    )
    print(result.stdout, end="")
    print(result.stderr, end="")
    print(f"exit={result.returncode}")
    report = json.loads(result.stdout)
    rows = {row["key"]: row for row in report["checks"]}
    assert result.returncode == 11, "valid config without secrets must exit 11"
    assert rows["config"]["ok"] and rows["config"]["value"] == "OK", report
PYTHON
```

- The example selects the OpenAI-compatible route, which requires a base URL. The managed
  `openai-chatgpt/<model>` route does not require one; its credentials are checked separately.
- `doctor --check-config` validates config **and secrets**, including MCP config/credentials
  and optional local sandbox availability. It may create the state directory, but does not
  open the database or run live network/Codex probes. Missing secrets exit **11** even when
  `config` is `OK`; invalid config exits **10** (`ClawExitCode`).
- For a negative config case, change the relevant key and assert exit 10 and the failed config
  row. Check the intended row as well as the exit code; another failure can mask your case.

## Live diagnostics, only when relevant

Before deliberately checking a configured installation or tool backend, read the corresponding
section of `docs/LOCAL_DEV.md`. Full `doctor` can open/migrate the database and probe DNS,
Telegram, MCP, native Coder or the VM sandbox depending on config. It needs explicit test
configuration and can have additional failures beyond missing secrets.

Bound every clawd invocation with a process timeout (as above, or GNU `timeout`/`gtimeout` if
installed); tool output-yield intervals are not process deadlines. Preserve the command's status
before filtering output. For DNS checks, inspect the `dns.fake_ip` row: a fake-IP VPN/proxy can
answer even nonexistent hostnames from `198.18.0.0/15`.
