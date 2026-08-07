'''Deprecated Codex-only test retained for migration reference.
"""Integration tests for the managed Codex worktree handoff helper."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


HELPER = Path(__file__).parents[1] / "scripts" / "codex-worktree-handoff.py"


def run(command, cwd=None, env=None, check=True):
    """Run one subprocess for the integration fixture."""
    result = subprocess.run(
        command,
        cwd=cwd,
        env=env,
        check=False,
        capture_output=True,
        text=True,
    )
    if check and result.returncode != 0:
        raise AssertionError(result.stderr or result.stdout)
    return result


class WorktreeHandoffTest(unittest.TestCase):
    """Exercise successful and rejected handoffs against a local remote."""

    def setUp(self):
        """Create a repository, local origin, and fake Neovim client."""
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.origin = self.root / "origin.git"
        self.repository = self.root / "source"
        self.home = self.root / "home"
        self.fake_bin = self.root / "bin"

        run(["git", "init", "--bare", "--initial-branch=main", self.origin])
        run(["git", "init", "-b", "main", self.repository])
        run(
            [
                "git",
                "-C",
                self.repository,
                "-c",
                "user.name=Codex Worktree Test",
                "-c",
                "user.email=codex-worktree@example.com",
                "commit",
                "--allow-empty",
                "-m",
                "initial",
            ]
        )
        run(["git", "-C", self.repository, "remote", "add", "origin", self.origin])
        run(["git", "-C", self.repository, "push", "-u", "origin", "main"])

        self.fake_bin.mkdir()
        fake_nvim = self.fake_bin / "nvim"
        fake_nvim.write_text(
            "#!/bin/sh\n"
            'if [ "$4" = "1" ]; then\n'
            "  printf '1\\n'\n"
            'elif [ "$REJECT_HANDOFF" = "1" ]; then\n'
            "  printf 'rejected\\n'\n"
            "else\n"
            "  printf 'scheduled\\n'\n"
            "fi\n"
        )
        fake_nvim.chmod(0o755)

        self.environment = os.environ.copy()
        self.environment.update(
            {
                "CODEX_NVIM_SERVER": str(self.root / "nvim.sock"),
                "CODEX_NVIM_SLOT_ID": "7",
                "CODEX_THREAD_ID": "abc-def",
                "HOME": str(self.home),
                "PATH": f"{self.fake_bin}{os.pathsep}{self.environment['PATH']}",
            }
        )

    def tearDown(self):
        """Remove the isolated integration fixture."""
        self.temporary_directory.cleanup()

    def invoke(self, name, reject=False):
        """Run the helper with optional Neovim registration rejection."""
        environment = self.environment.copy()
        if reject:
            environment["REJECT_HANDOFF"] = "1"
        return run(
            [sys.executable, HELPER, name],
            cwd=self.repository,
            env=environment,
            check=False,
        )

    def test_creates_unique_worktree_from_origin_main(self):
        """Create a uniquely named managed worktree at the fetched main commit."""
        run(["git", "-C", self.repository, "branch", "task"])

        result = self.invoke("task")

        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        target = self.home / ".codex" / "worktrees" / "source" / "task-2"
        origin_main = run(
            ["git", "-C", self.repository, "rev-parse", "origin/main"]
        ).stdout.strip()
        target_head = run(["git", "-C", target, "rev-parse", "HEAD"]).stdout.strip()
        self.assertEqual(payload["status"], "scheduled")
        self.assertEqual(payload["branch"], "task-2")
        self.assertEqual(Path(payload["new_worktree"]), target)
        self.assertEqual(payload["base_ref"], "origin/main")
        self.assertEqual(payload["base_commit"], origin_main)
        self.assertEqual(target_head, origin_main)

    def test_rolls_back_when_neovim_rejects_handoff(self):
        """Remove the worktree and branch when Neovim rejects registration."""
        result = self.invoke("rejected-task", reject=True)

        target = self.home / ".codex" / "worktrees" / "source" / "rejected-task"
        branch = run(
            [
                "git",
                "-C",
                self.repository,
                "show-ref",
                "--verify",
                "--quiet",
                "refs/heads/rejected-task",
            ],
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Neovim rejected the worktree handoff", result.stderr)
        self.assertFalse(target.exists())
        self.assertNotEqual(branch.returncode, 0)


if __name__ == "__main__":
    unittest.main()
'''
