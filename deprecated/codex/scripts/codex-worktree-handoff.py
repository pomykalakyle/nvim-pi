'''Deprecated Codex-only implementation retained for migration reference.
#!/usr/bin/env python3
"""Create a managed worktree and schedule the current Codex conversation to resume there."""

import argparse
import base64
import json
import os
from pathlib import Path
import re
import subprocess
import sys


NAME_PATTERN = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
BASE_REF = "origin/main"


def run(command, cwd=None, check=True):
    """Run one subprocess and return its completed result."""
    result = subprocess.run(
        command,
        cwd=cwd,
        check=False,
        capture_output=True,
        text=True,
    )
    if check and result.returncode != 0:
        message = result.stderr.strip() or result.stdout.strip() or "command failed"
        raise RuntimeError(message)
    return result


def git(repo, *args, check=True):
    """Run one Git command in a repository."""
    return run(["git", "-C", str(repo), *args], check=check)


def require_environment(name):
    """Return one required environment variable."""
    value = os.environ.get(name, "")
    if not value:
        raise RuntimeError(f"{name} is required")
    return value


def validate_identifier(value, label):
    """Validate a UUID-like Codex runtime identifier."""
    if not re.fullmatch(r"[A-Fa-f0-9-]+", value):
        raise RuntimeError(f"{label} contains unsafe characters")
    return value


def repository_root():
    """Return the Git worktree containing the current process."""
    result = run(["git", "rev-parse", "--show-toplevel"])
    return Path(result.stdout.strip()).resolve()


def main_worktree(repo):
    """Return the repository's main worktree from Git porcelain output."""
    output = git(repo, "worktree", "list", "--porcelain").stdout.splitlines()
    if not output or not output[0].startswith("worktree "):
        raise RuntimeError("Git did not report a main worktree")
    return Path(output[0][len("worktree ") :]).resolve()


def branch_exists(repo, name):
    """Report whether a local branch already uses a candidate name."""
    result = git(repo, "show-ref", "--verify", "--quiet", f"refs/heads/{name}", check=False)
    return result.returncode == 0


def unique_name(repo, directory, requested):
    """Choose a branch and directory name that are unused."""
    candidate = requested
    suffix = 2
    while branch_exists(repo, candidate) or (directory / candidate).exists():
        candidate = f"{requested}-{suffix}"
        suffix += 1
    return candidate


def preflight_neovim(server):
    """Verify that the configured Neovim RPC server is reachable."""
    result = run(
        ["nvim", "--server", server, "--remote-expr", "1"],
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError("Neovim is unavailable")


def schedule_handoff(server, payload):
    """Register the new worktree with the running Neovim instance."""
    encoded = base64.b64encode(json.dumps(payload, separators=(",", ":")).encode()).decode()
    expression = (
        "luaeval(\"require('config.codex_worktree').schedule_handoff(_A)\", "
        f'"{encoded}")'
    )
    result = run(
        ["nvim", "--server", server, "--remote-expr", expression],
        check=False,
    )
    if result.returncode != 0 or result.stdout.strip() != "scheduled":
        raise RuntimeError("Neovim rejected the worktree handoff")


def rollback(repo, worktree, branch):
    """Remove only the worktree and branch created by this invocation."""
    git(repo, "worktree", "remove", "--force", str(worktree), check=False)
    git(repo, "branch", "-D", branch, check=False)


def parse_args():
    """Parse the requested task-relevant worktree name."""
    parser = argparse.ArgumentParser()
    parser.add_argument("name")
    args = parser.parse_args()
    if not NAME_PATTERN.fullmatch(args.name):
        parser.error("name must use lowercase letters, numbers, dots, underscores, or hyphens")
    return args


def main():
    """Create the worktree and schedule the current conversation handoff."""
    args = parse_args()
    server = require_environment("CODEX_NVIM_SERVER")
    slot_id = validate_identifier(require_environment("CODEX_NVIM_SLOT_ID"), "CODEX_NVIM_SLOT_ID")
    session_id = validate_identifier(require_environment("CODEX_THREAD_ID"), "CODEX_THREAD_ID")
    preflight_neovim(server)

    original_worktree = repository_root()
    main_root = main_worktree(original_worktree)
    repository_name = main_root.name
    managed_directory = Path.home() / ".codex" / "worktrees" / repository_name

    git(original_worktree, "fetch", "origin", "main")
    base_commit = git(original_worktree, "rev-parse", BASE_REF).stdout.strip()
    name = unique_name(original_worktree, managed_directory, args.name)
    target = managed_directory / name
    managed_directory.mkdir(parents=True, exist_ok=True)

    git(original_worktree, "worktree", "add", "-b", name, str(target), base_commit)
    payload = {
        "base_commit": base_commit,
        "base_ref": BASE_REF,
        "branch": name,
        "new_worktree": str(target),
        "old_worktree": str(original_worktree),
        "session_id": session_id,
        "slot_id": slot_id,
    }

    try:
        schedule_handoff(server, payload)
    except (OSError, RuntimeError, subprocess.SubprocessError):
        rollback(original_worktree, target, name)
        raise

    print(json.dumps({"status": "scheduled", **payload}, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"codex-worktree-handoff: {error}", file=sys.stderr)
        raise SystemExit(1)
'''
