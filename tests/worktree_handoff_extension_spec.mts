import assert from "node:assert/strict";
import { access, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  registerWorktreeHandoff,
  type HandoffDependencies,
} from "../pi-extensions/worktree-handoff/extension.ts";
import type { ManagedWorktree } from "../pi-extensions/worktree-handoff/git.ts";

const managed: ManagedWorktree = {
  sourceRoot: "/repo",
  path: "/managed/task",
  branch: "task",
  baseRef: "origin/main",
  baseCommit: "abc123",
};

type RegisteredTool = {
  execute(...args: unknown[]): Promise<unknown>;
};
type SettledHandler = (event: unknown, ctx: unknown) => Promise<void>;

/** Register one isolated extension instance against fake Pi APIs. */
function register(dependencies: HandoffDependencies) {
  let tool: RegisteredTool | undefined;
  let settled: SettledHandler | undefined;
  const pi = {
    registerTool(value: RegisteredTool) {
      tool = value;
    },
    on(event: string, handler: SettledHandler) {
      if (event === "agent_settled") settled = handler;
    },
  };
  registerWorktreeHandoff(pi as never, dependencies);
  return { tool: tool!, settled: settled! };
}

const calls: string[] = [];
const dependencies: HandoffDependencies = {
  async createWorktree(cwd, name) {
    calls.push(`create:${cwd}:${name}`);
    return managed;
  },
  async rollbackWorktree() {
    calls.push("rollback");
  },
  forkSession(source, target) {
    calls.push(`fork:${source}:${target}`);
    return "/managed/session.jsonl";
  },
  async openSession(worktree, session) {
    calls.push(`open:${worktree}:${session}`);
  },
};

const extension = register(dependencies);
const context = {
  cwd: "/repo",
  sessionManager: { getSessionFile: () => "/source/session.jsonl" },
  ui: { notify: () => undefined },
};
const result = await extension.tool.execute("call", { name: "task" }, undefined, undefined, context);
assert.equal((result as { terminate: boolean }).terminate, true);
assert.deepEqual(calls, ["create:/repo:task"]);
await extension.settled({}, context);
assert.deepEqual(calls, [
  "create:/repo:task",
  "fork:/source/session.jsonl:/managed/task",
  "open:/managed/task:/managed/session.jsonl",
]);

let rolledBack = false;
let notification = "";
const forkFile = join(tmpdir(), `pi-worktree-fork-${process.pid}-${Date.now()}.jsonl`);
await writeFile(forkFile, "forked session");
const failing = register({
  ...dependencies,
  async rollbackWorktree() {
    rolledBack = true;
    throw new Error("rollback exploded");
  },
  forkSession() {
    return forkFile;
  },
  async openSession() {
    throw new Error("Neovim rejected handoff");
  },
});
const failingContext = {
  ...context,
  ui: { notify: (message: string) => notification = message },
};
await failing.tool.execute("call", { name: "task" }, undefined, undefined, failingContext);
await failing.settled({}, failingContext);
assert(rolledBack);
assert.match(notification, /Neovim rejected handoff/);
assert.match(notification, /rollback exploded/);
await assert.rejects(access(forkFile));

const controller = new AbortController();
let cancelledRollback = false;
const cancelled = register({
  ...dependencies,
  async createWorktree() {
    controller.abort();
    return managed;
  },
  async rollbackWorktree() {
    cancelledRollback = true;
  },
});
await assert.rejects(
  cancelled.tool.execute("call", { name: "task" }, controller.signal, undefined, context),
  /cancelled/,
);
assert(cancelledRollback);

console.log("worktree-handoff-extension-spec-ok");
