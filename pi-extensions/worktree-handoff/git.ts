import { execFile } from "node:child_process";
import { access, mkdir } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, join, resolve } from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const NAME_PATTERN = /^[a-z0-9][a-z0-9._-]*$/;
const BASE_REF = "origin/main";

export type ManagedWorktree = {
  sourceRoot: string;
  path: string;
  branch: string;
  baseRef: string;
  baseCommit: string;
};

/**
 * Run Git and return trimmed stdout, preserving its useful failure message.
 * Reviewed: false.
 */
async function git(cwd: string, args: string[], signal?: AbortSignal): Promise<string> {
  try {
    const result = await execFileAsync("git", ["-C", cwd, ...args], {
      encoding: "utf8",
      signal,
    });
    return result.stdout.trim();
  } catch (error) {
    if (error && typeof error === "object") {
      const failure = error as { stderr?: string; stdout?: string; message?: string };
      throw new Error(failure.stderr?.trim() || failure.stdout?.trim() || failure.message || "Git failed");
    }
    throw error;
  }
}

/**
 * Report whether a filesystem path already exists.
 * Reviewed: false.
 */
async function pathExists(path: string): Promise<boolean> {
  try {
    await access(path);
    return true;
  } catch {
    return false;
  }
}

/**
 * Choose a branch and directory name unused by the repository.
 * Reviewed: false.
 */
async function uniqueName(
  repo: string,
  directory: string,
  requested: string,
  signal?: AbortSignal,
): Promise<string> {
  let candidate = requested;
  let suffix = 2;
  while (
    await pathExists(join(directory, candidate))
    || (await git(repo, ["show-ref", "--verify", "--quiet", `refs/heads/${candidate}`], signal).then(
      /** Reviewed: false. */ () => true,
      /** Reviewed: false. */ () => false,
    ))
  ) {
    candidate = `${requested}-${suffix}`;
    suffix += 1;
  }
  return candidate;
}

/**
 * Create a uniquely named managed worktree from the latest origin/main.
 * Reviewed: false.
 */
export async function createManagedWorktree(
  cwd: string,
  requested: string,
  signal?: AbortSignal,
): Promise<ManagedWorktree> {
  if (!NAME_PATTERN.test(requested)) {
    throw new Error("Worktree names must use lowercase letters, numbers, dots, underscores, or hyphens");
  }

  const sourceRoot = resolve(await git(cwd, ["rev-parse", "--show-toplevel"], signal));
  const porcelain = await git(sourceRoot, ["worktree", "list", "--porcelain"], signal);
  const mainLine = porcelain.split("\n").find(/** Reviewed: false. */ (line) => line.startsWith("worktree "));
  if (!mainLine) throw new Error("Git did not report a main worktree");

  await git(sourceRoot, ["fetch", "origin", "main"], signal);
  const baseCommit = await git(sourceRoot, ["rev-parse", BASE_REF], signal);
  const repositoryName = basename(resolve(mainLine.slice("worktree ".length)));
  const managedDirectory = join(homedir(), ".pi", "worktrees", repositoryName);
  await mkdir(managedDirectory, { recursive: true });

  const branch = await uniqueName(sourceRoot, managedDirectory, requested, signal);
  const path = join(managedDirectory, branch);
  signal?.throwIfAborted();
  await git(sourceRoot, ["worktree", "add", "-b", branch, path, baseCommit]);
  const worktree = { sourceRoot, path, branch, baseRef: BASE_REF, baseCommit };
  if (signal?.aborted) {
    await rollbackManagedWorktree(worktree);
    signal.throwIfAborted();
  }
  return worktree;
}

/**
 * Remove only the worktree and branch created by this handoff attempt.
 * Reviewed: false.
 */
export async function rollbackManagedWorktree(worktree: ManagedWorktree): Promise<void> {
  const failures: string[] = [];
  await git(worktree.sourceRoot, ["worktree", "remove", "--force", worktree.path]).catch(/** Reviewed: false. */ (error) => {
    failures.push(error instanceof Error ? error.message : String(error));
  });
  await git(worktree.sourceRoot, ["branch", "-D", worktree.branch]).catch(/** Reviewed: false. */ (error) => {
    failures.push(error instanceof Error ? error.message : String(error));
  });
  if (failures.length > 0) throw new Error(`Worktree rollback failed: ${failures.join(" ")}`);
}
