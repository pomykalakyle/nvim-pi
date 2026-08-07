'''Deprecated Codex-only implementation retained for migration reference.
#!/usr/bin/env python3
"""Bridge Codex lifecycle hooks to the active Neovim hands-free controller."""

import base64
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import uuid


def emit_stop_success(payload):
    """Emit the JSON object required by successful Stop hooks."""
    if payload.get("hook_event_name") == "Stop":
        print("{}")


def marker_path(state_dir, slot_id):
    """Return the active-mode marker for one terminal slot."""
    return Path(state_dir) / f"active-{slot_id}"


def call_neovim(payload, server):
    """Send one encoded hook payload to the running Neovim instance."""
    encoded = base64.b64encode(json.dumps(payload, separators=(",", ":")).encode()).decode()
    expression = (
        "luaeval(\"require('config.codex_hook_bridge').handle_hook_payload(_A)\", "
        f'"{encoded}")'
    )
    result = subprocess.run(
        ["nvim", "--server", server, "--remote-expr", expression],
        check=False,
        capture_output=True,
        text=True,
        timeout=4,
    )
    if result.returncode != 0:
        return None
    return result.stdout.strip()


def wait_for_decision(state_dir, request_id, timeout_seconds=590):
    """Wait for the atomic decision file belonging to one approval request."""
    decision_path = Path(state_dir) / f"decision-{request_id}.json"
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        try:
            with decision_path.open(encoding="utf-8") as handle:
                decision = json.load(handle)
            decision_path.unlink(missing_ok=True)
            return decision.get("behavior")
        except FileNotFoundError:
            time.sleep(0.1)
        except (OSError, ValueError):
            return "deny"
    return "deny"


def emit_permission_decision(behavior):
    """Return an allow or deny decision using the Codex hook schema."""
    decision = {"behavior": behavior}
    if behavior == "deny":
        decision["message"] = "Rejected through Hands-Free Mode."
    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PermissionRequest",
                    "decision": decision,
                }
            }
        )
    )


def main():
    """Read one Codex hook payload and bridge it to Neovim."""
    try:
        payload = json.load(sys.stdin)
    except (OSError, ValueError):
        return 0

    server = os.environ.get("CODEX_NVIM_SERVER", "")
    slot_id = os.environ.get("CODEX_NVIM_SLOT_ID", "")
    state_dir = os.environ.get("CODEX_HANDSFREE_STATE_DIR", "")
    event_name = payload.get("hook_event_name")
    if not server or not slot_id or not state_dir:
        emit_stop_success(payload)
        return 0

    payload["_handsfree_slot_id"] = slot_id
    if event_name == "PermissionRequest":
        if not marker_path(state_dir, slot_id).exists():
            return 0
        request_id = uuid.uuid4().hex
        payload["_handsfree_request_id"] = request_id
        try:
            response = call_neovim(payload, server)
        except (OSError, subprocess.SubprocessError):
            response = None
        if response != "pending":
            emit_permission_decision("deny")
            return 0
        behavior = wait_for_decision(state_dir, request_id)
        emit_permission_decision("allow" if behavior == "allow" else "deny")
        return 0

    try:
        call_neovim(payload, server)
    except (OSError, subprocess.SubprocessError):
        pass
    emit_stop_success(payload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
'''
