import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { access, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  createManagedWorktree,
  rollbackManagedWorktree,
} from "../pi-extensions/worktree-handoff/git.ts";

/** Run one Git command and return trimmed stdout. */
function git(cwd: string, args: string[]): string {
  return execFileSync("git", ["-C", cwd, ...args], { encoding: "utf8" }).trim();
}

const root = await mkdtemp(join(tmpdir(), "pi-worktree-handoff-"));
const originalHome = process.env.HOME;
const origin = join(root, "origin.git");
const source = join(root, "source");
const updater = join(root, "updater");

try {
  execFileSync("git", ["init", "--bare", "--initial-branch=main", origin]);
  execFileSync("git", ["init", "-b", "main", source]);
  git(source, ["config", "user.name", "Pi Worktree Test"]);
  git(source, ["config", "user.email", "pi-worktree@example.com"]);
  git(source, ["commit", "--allow-empty", "-m", "initial"]);
  git(source, ["remote", "add", "origin", origin]);
  git(source, ["push", "-u", "origin", "main"]);
  git(source, ["branch", "task"]);
  execFileSync("git", ["clone", origin, updater]);
  git(updater, ["config", "user.name", "Pi Worktree Test"]);
  git(updater, ["config", "user.email", "pi-worktree@example.com"]);
  git(updater, ["commit", "--allow-empty", "-m", "remote update"]);
  git(updater, ["push", "origin", "main"]);
  const latestMain = git(updater, ["rev-parse", "HEAD"]);
  process.env.HOME = join(root, "home");

  const worktree = await createManagedWorktree(source, "task");
  assert.equal(worktree.branch, "task-2");
  assert.equal(worktree.path, join(process.env.HOME, ".pi", "worktrees", "source", "task-2"));
  assert.equal(worktree.baseRef, "origin/main");
  assert.equal(git(worktree.path, ["rev-parse", "HEAD"]), latestMain);

  await rollbackManagedWorktree(worktree);
  await assert.rejects(access(worktree.path));
  const branch = spawnSync("git", ["-C", source, "show-ref", "--verify", "refs/heads/task-2"]);
  assert.notEqual(branch.status, 0);
  await assert.rejects(createManagedWorktree(source, "Invalid Name"), /lowercase letters/);
} finally {
  process.env.HOME = originalHome;
  await rm(root, { recursive: true, force: true });
}

console.log("worktree-handoff-git-spec-ok");
