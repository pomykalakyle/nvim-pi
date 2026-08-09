import assert from "node:assert/strict";
import {
  mkdir,
  mkdtemp,
  readFile,
  rm,
  symlink,
  unlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { registerNeovimDiffPreview } from "../pi-extensions/neovim-diff-preview/index.js";
import {
  publishVibingModeService,
  unpublishVibingModeService,
} from "../pi-extensions/vibing-mode/shared.js";

const serviceKey = Symbol.for("@gotgenes/pi-permission-system:service");
const registry = globalThis as Record<symbol, unknown>;
const tools: Array<Record<string, unknown>> = [];
const handlers = new Map<string, Function[]>();
const commands = new Map<string, Record<string, unknown>>();
const eventHandlers = new Map<string, Function>();
const entries: Array<Record<string, unknown>> = [];
const sentMessages: Array<{
  message: Record<string, unknown>;
  options: Record<string, unknown>;
}> = [];
let authorizer: Function | undefined;

registry[serviceKey] = {
  registerAuthorizer(name: string, callback: Function) {
    assert.equal(name, "neovim-diff-preview");
    authorizer = callback;
    return () => {
      authorizer = undefined;
    };
  },
};

const pi = {
  registerTool(tool: unknown) {
    tools.push(tool as Record<string, unknown>);
  },
  registerCommand(name: string, command: Record<string, unknown>) {
    commands.set(name, command);
  },
  appendEntry(customType: string, data: unknown) {
    entries.push({ type: "custom", customType, data });
  },
  sendMessage(
    message: Record<string, unknown>,
    options: Record<string, unknown>,
  ) {
    sentMessages.push({ message, options });
  },
  events: {
    on(event: string, handler: Function) {
      eventHandlers.set(event, handler);
      return () => eventHandlers.delete(event);
    },
  },
  on(event: string, handler: Function) {
    const registered = handlers.get(event) ?? [];
    registered.push(handler);
    handlers.set(event, registered);
  },
} as unknown as ExtensionAPI;

let capturedProposal: Record<string, unknown> | undefined;
let previewOutcome: "reject" | "throw" | "success" = "reject";
const refreshed: string[] = [];
const closed: string[] = [];
let previewReloads = 0;
registerNeovimDiffPreview(pi, {
  async openPreview(proposal) {
    if (previewOutcome === "throw") throw new Error("Neovim RPC disconnected");
    capturedProposal = proposal as unknown as Record<string, unknown>;
    if (previewOutcome === "success") {
      return {
        ok: true,
        file_path: proposal.filePath,
        preview_rows: 5,
        viewport_rows: 20,
      };
    }
    return {
      ok: false,
      reason: "preview_too_tall",
      message: "The proposal does not fit",
      preview_rows: 40,
      viewport_rows: 20,
    };
  },
  async refreshBuffer(filePath) {
    refreshed.push(filePath);
  },
  async closePreview(toolCallId) {
    closed.push(toolCallId);
  },
  async reloadPreview() {
    previewReloads++;
  },
});

const toolCall = handlers.get("tool_call")?.[0];
const toolResult = handlers.get("tool_result")?.[0];
const executionEnd = handlers.get("tool_execution_end")?.[0];
const sessionStart = handlers.get("session_start")?.[0];
const sessionTree = handlers.get("session_tree")?.[0];
const turnEnd = handlers.get("turn_end")?.[0];
const beforeAgentStart = handlers.get("before_agent_start")?.[0];
assert(
  toolCall &&
    toolResult &&
    executionEnd &&
    sessionStart &&
    sessionTree &&
    turnEnd &&
    beforeAgentStart,
);

const directory = await mkdtemp(join(tmpdir(), "nvim-pi-preview-extension-"));
try {
  const path = join(directory, "example.txt");
  await writeFile(path, "before\n", "utf8");
  const input = {
    path: "example.txt",
    edits: [{ oldText: "before", newText: "after" }],
    unfolded_ranges: [{ start_line: 1, end_line: 1 }],
  };
  const notifications: string[] = [];
  const statuses: Array<string | undefined> = [];
  let aborts = 0;
  const context = {
    cwd: directory,
    signal: undefined,
    sessionManager: {
      getBranch() {
        return entries;
      },
    },
    ui: {
      notify(message: string) {
        notifications.push(message);
      },
      setStatus(_key: string, value: string | undefined) {
        statuses.push(value);
      },
    },
    abort() {
      aborts++;
    },
    async waitForIdle() {},
  };

  await sessionStart({ reason: "startup" }, context);
  assert.equal(previewReloads, 1);
  assert(authorizer);

  const rejectedPreview = await toolCall(
    { toolName: "edit", toolCallId: "blocked-edit", input },
    context,
  );
  assert.equal(rejectedPreview.block, true);
  assert(String(rejectedPreview.reason).includes("Tighten unfolded_ranges"));
  assert.deepEqual(capturedProposal?.unfoldedRanges, input.unfolded_ranges);
  assert.equal(await readFile(path, "utf8"), "before\n");

  previewOutcome = "throw";
  const unavailable = await toolCall(
    { toolName: "edit", toolCallId: "unavailable-edit", input },
    context,
  );
  assert.equal(unavailable.block, true);
  assert(
    String(unavailable.reason).includes("edit/write call was not executed"),
  );
  assert(notifications.at(-1)?.includes("Neovim RPC disconnected"));

  previewOutcome = "success";
  const staged = await toolCall(
    { toolName: "edit", toolCallId: "pending-edit", input },
    context,
  );
  assert.equal(staged, undefined);
  const verdict = await authorizer(
    {
      source: "tool_call",
      requestId: "request-1",
      toolCallId: "pending-edit",
      toolName: "edit",
      path,
    },
    {},
    { review() {} },
  );
  assert.deepEqual(verdict, { kind: "allow" });
  const wrongCallVerdict = await authorizer(
    {
      source: "tool_call",
      requestId: "request-2",
      toolCallId: "another-edit",
      toolName: "edit",
      path,
    },
    {},
    { review() {} },
  );
  assert.deepEqual(wrongCallVerdict, { kind: "defer" });

  const edit = tools.find((tool) => tool.name === "edit");
  const resolveProposal = tools.find((tool) => tool.name === "resolve_proposal");
  assert(edit && typeof edit.execute === "function");
  assert(resolveProposal && typeof resolveProposal.execute === "function");
  const pendingResult = await (edit.execute as Function)(
    "pending-edit",
    input,
    undefined,
    undefined,
    context,
  );
  assert.equal(await readFile(path, "utf8"), "before\n");
  assert.equal(pendingResult.details.proposalPending, true);
  assert.equal(pendingResult.terminate, true);
  assert(String(pendingResult.content[0].text).includes("has not changed"));
  await turnEnd({}, context);
  assert.equal(aborts, 1);

  await toolResult(
    {
      toolName: "edit",
      toolCallId: "pending-edit",
      input,
      isError: false,
      content: pendingResult.content,
      details: pendingResult.details,
    },
    context,
  );
  assert.deepEqual(refreshed, []);
  await executionEnd({ toolName: "edit", toolCallId: "pending-edit" }, context);
  assert.deepEqual(closed, []);
  assert(statuses.at(-1)?.includes("/proposal accept|reject"));

  const scoped = beforeAgentStart({ systemPrompt: "base" }, context);
  assert(String(scoped.systemPrompt).includes("conversation is scoped"));
  assert(String(scoped.systemPrompt).includes("Do not run tests"));
  assert(String(scoped.systemPrompt).includes("call resolve_proposal"));

  const blockedBash = await toolCall(
    {
      toolName: "bash",
      toolCallId: "bash-while-pending",
      input: { command: "npm test" },
    },
    context,
  );
  assert.equal(blockedBash.block, true);

  const otherFile = await toolCall(
    {
      toolName: "write",
      toolCallId: "other-file",
      input: {
        path: "other.txt",
        content: "nope\n",
        unfolded_ranges: [{ start_line: 1, end_line: 1 }],
      },
    },
    context,
  );
  assert.equal(otherFile.block, true);
  assert(String(otherFile.reason).includes("already pending"));

  const revisionInput = {
    ...input,
    edits: [{ oldText: "before", newText: "revised" }],
  };
  await toolCall(
    { toolName: "edit", toolCallId: "revised-edit", input: revisionInput },
    context,
  );
  const revisionResult = await (edit.execute as Function)(
    "revised-edit",
    revisionInput,
    undefined,
    undefined,
    context,
  );
  assert.equal(revisionResult.details.proposalPending, true);
  assert.equal(await readFile(path, "utf8"), "before\n");
  await executionEnd({ toolName: "edit", toolCallId: "revised-edit" }, context);

  const proposalCommand = commands.get("proposal");
  assert(proposalCommand && typeof proposalCommand.handler === "function");
  await sessionTree({}, context);
  await (proposalCommand.handler as Function)("accept", context);
  assert.equal(await readFile(path, "utf8"), "revised\n");
  assert(closed.includes("revised-edit"));
  assert.equal(sentMessages.at(-1)?.message.customType, "nvim-pi-proposal-resolution");
  assert.equal(sentMessages.at(-1)?.message.content, "Proposal accepted.");
  assert.deepEqual(sentMessages.at(-1)?.options, { triggerTurn: true });

  const rejectionInput = {
    ...input,
    edits: [{ oldText: "revised", newText: "rejected" }],
  };
  await toolCall(
    { toolName: "edit", toolCallId: "rejected-edit", input: rejectionInput },
    context,
  );
  await (edit.execute as Function)(
    "rejected-edit",
    rejectionInput,
    undefined,
    undefined,
    context,
  );
  await executionEnd(
    { toolName: "edit", toolCallId: "rejected-edit" },
    context,
  );
  const messagesBeforeVerbalRejection = sentMessages.length;
  const rejectionResult = await (resolveProposal.execute as Function)(
    "resolve-rejection",
    { action: "reject" },
    undefined,
    undefined,
    context,
  );
  assert.equal(await readFile(path, "utf8"), "revised\n");
  assert.equal(statuses.at(-1), undefined);
  assert.deepEqual(rejectionResult.details, {
    action: "reject",
    path: "example.txt",
  });
  assert.equal(sentMessages.length, messagesBeforeVerbalRejection);
  const noProposalResult = await (resolveProposal.execute as Function)(
    "resolve-without-proposal",
    { action: "reject" },
    undefined,
    undefined,
    context,
  );
  assert.equal(noProposalResult.details, undefined);
  assert.equal(
    await toolCall(
      {
        toolName: "bash",
        toolCallId: "bash-after-reject",
        input: { command: "true" },
      },
      context,
    ),
    undefined,
  );

  const acceptedInput = {
    ...input,
    edits: [{ oldText: "revised", newText: "after" }],
  };
  await toolCall(
    { toolName: "edit", toolCallId: "accepted-edit", input: acceptedInput },
    context,
  );
  await (edit.execute as Function)(
    "accepted-edit",
    acceptedInput,
    undefined,
    undefined,
    context,
  );
  await executionEnd(
    { toolName: "edit", toolCallId: "accepted-edit" },
    context,
  );
  const acceptanceResult = await (resolveProposal.execute as Function)(
    "resolve-acceptance",
    { action: "accept" },
    undefined,
    undefined,
    context,
  );
  assert.equal(await readFile(path, "utf8"), "after\n");
  assert.deepEqual(refreshed, [path, path]);
  assert(closed.includes("accepted-edit"));
  assert.deepEqual(acceptanceResult.details, {
    action: "accept",
    path: "example.txt",
  });

  const write = tools.find((tool) => tool.name === "write");
  assert(write && typeof write.execute === "function");
  const newFileInput = {
    path: "new.txt",
    content: "new file\n",
    unfolded_ranges: [{ start_line: 1, end_line: 1 }],
  };
  await toolCall(
    { toolName: "write", toolCallId: "new-write", input: newFileInput },
    context,
  );
  await (write.execute as Function)(
    "new-write",
    newFileInput,
    undefined,
    undefined,
    context,
  );
  await assert.rejects(readFile(join(directory, "new.txt"), "utf8"), /ENOENT/);
  await executionEnd({ toolName: "write", toolCallId: "new-write" }, context);
  await (proposalCommand.handler as Function)("accept", context);
  assert.equal(
    await readFile(join(directory, "new.txt"), "utf8"),
    "new file\n",
  );

  const createdElsewhereInput = {
    path: "created-elsewhere.txt",
    content: "proposal\n",
    unfolded_ranges: [{ start_line: 1, end_line: 1 }],
  };
  await toolCall(
    {
      toolName: "write",
      toolCallId: "created-elsewhere",
      input: createdElsewhereInput,
    },
    context,
  );
  await (write.execute as Function)(
    "created-elsewhere",
    createdElsewhereInput,
    undefined,
    undefined,
    context,
  );
  await executionEnd(
    { toolName: "write", toolCallId: "created-elsewhere" },
    context,
  );
  await writeFile(
    join(directory, "created-elsewhere.txt"),
    "external\n",
    "utf8",
  );
  await (proposalCommand.handler as Function)("accept", context);
  assert.equal(
    await readFile(join(directory, "created-elsewhere.txt"), "utf8"),
    "external\n",
  );
  assert(notifications.at(-1)?.includes("changed after it was proposed"));
  await (proposalCommand.handler as Function)("reject", context);

  const conflictInput = {
    ...input,
    edits: [{ oldText: "after", newText: "conflict proposal" }],
  };
  await toolCall(
    { toolName: "edit", toolCallId: "conflict-edit", input: conflictInput },
    context,
  );
  await (edit.execute as Function)(
    "conflict-edit",
    conflictInput,
    undefined,
    undefined,
    context,
  );
  await executionEnd(
    { toolName: "edit", toolCallId: "conflict-edit" },
    context,
  );
  await writeFile(path, "changed outside proposal\n", "utf8");
  await (proposalCommand.handler as Function)("accept", context);
  assert.equal(await readFile(path, "utf8"), "changed outside proposal\n");
  assert(notifications.at(-1)?.includes("changed after it was proposed"));
  const stillPending = await toolCall(
    {
      toolName: "bash",
      toolCallId: "still-pending",
      input: { command: "true" },
    },
    context,
  );
  assert.equal(stillPending.block, true);
  await (proposalCommand.handler as Function)("reject", context);

  const unavailableRestoreInput = {
    ...input,
    edits: [{ oldText: "changed outside proposal", newText: "unavailable" }],
  };
  await toolCall(
    {
      toolName: "edit",
      toolCallId: "unavailable-restore",
      input: unavailableRestoreInput,
    },
    context,
  );
  await (edit.execute as Function)(
    "unavailable-restore",
    unavailableRestoreInput,
    undefined,
    undefined,
    context,
  );
  await executionEnd(
    { toolName: "edit", toolCallId: "unavailable-restore" },
    context,
  );
  previewOutcome = "reject";
  const failedRevision = await toolCall(
    {
      toolName: "edit",
      toolCallId: "failed-revision",
      input: {
        ...unavailableRestoreInput,
        edits: [
          { oldText: "changed outside proposal", newText: "failed revision" },
        ],
      },
    },
    context,
  );
  assert.equal(failedRevision.block, true);
  await sessionTree({}, context);
  await (proposalCommand.handler as Function)("accept", context);
  assert.equal(await readFile(path, "utf8"), "changed outside proposal\n");
  assert(notifications.at(-1)?.includes("diff is not active"));
  await (proposalCommand.handler as Function)("reject", context);
  previewOutcome = "success";

  const absoluteCrossWorktreeInput = {
    ...unavailableRestoreInput,
    path,
  };
  await toolCall(
    {
      toolName: "edit",
      toolCallId: "cross-worktree",
      input: absoluteCrossWorktreeInput,
    },
    context,
  );
  await (edit.execute as Function)(
    "cross-worktree",
    absoluteCrossWorktreeInput,
    undefined,
    undefined,
    context,
  );
  await executionEnd(
    { toolName: "edit", toolCallId: "cross-worktree" },
    context,
  );
  const otherWorktree = join(directory, "other-worktree");
  await mkdir(otherWorktree);
  await sessionTree({}, { ...context, cwd: otherWorktree });
  assert(notifications.at(-1)?.includes("another working directory"));
  assert.equal(
    await toolCall(
      {
        toolName: "bash",
        toolCallId: "bash-after-cross-cwd",
        input: { command: "true" },
      },
      context,
    ),
    undefined,
  );

  const firstTarget = join(directory, "target-one.txt");
  const secondTarget = join(directory, "target-two.txt");
  const linkPath = join(directory, "linked.txt");
  await writeFile(firstTarget, "linked before\n", "utf8");
  await writeFile(secondTarget, "linked before\n", "utf8");
  await symlink("target-one.txt", linkPath);
  const symlinkInput = {
    path: "linked.txt",
    edits: [{ oldText: "linked before", newText: "linked after" }],
    unfolded_ranges: [{ start_line: 1, end_line: 1 }],
  };
  await toolCall(
    { toolName: "edit", toolCallId: "symlink-edit", input: symlinkInput },
    context,
  );
  const symlinkVerdict = await authorizer(
    {
      source: "tool_call",
      requestId: "symlink-request",
      toolCallId: "symlink-edit",
      toolName: "edit",
      accessIntent: {
        boundaryValue: capturedProposal?.mutationPath,
        matchValues: [linkPath, firstTarget],
      },
    },
    {},
    { review() {} },
  );
  assert.deepEqual(symlinkVerdict, { kind: "allow" });
  await (edit.execute as Function)(
    "symlink-edit",
    symlinkInput,
    undefined,
    undefined,
    context,
  );
  await executionEnd({ toolName: "edit", toolCallId: "symlink-edit" }, context);
  await unlink(linkPath);
  await symlink("target-two.txt", linkPath);
  await (proposalCommand.handler as Function)("accept", context);
  assert(notifications.at(-1)?.includes("resolves to a different file"));
  assert.equal(await readFile(firstTarget, "utf8"), "linked before\n");
  assert.equal(await readFile(secondTarget, "utf8"), "linked before\n");
  await (proposalCommand.handler as Function)("reject", context);

  await writeFile(path, "before\n", "utf8");
  const vibingService = {
    isActive: () => true,
    snapshot: () => ({ active: true, requestId: 1, root: directory }),
    shouldSuppressPreview: (toolName: string, toolPath: string) =>
      toolName === "edit" && toolPath === "example.txt",
  };
  publishVibingModeService(vibingService);
  const proposalBeforeVibing = capturedProposal;
  try {
    const vibingGate = await toolCall(
      { toolName: "edit", toolCallId: "vibing-edit", input },
      context,
    );
    assert.equal(vibingGate, undefined);
    assert.equal(capturedProposal, proposalBeforeVibing);
    await (edit.execute as Function)(
      "vibing-edit",
      input,
      undefined,
      undefined,
      context,
    );
    assert.equal(await readFile(path, "utf8"), "after\n");
  } finally {
    unpublishVibingModeService(vibingService);
  }
} finally {
  delete registry[serviceKey];
  await rm(directory, { recursive: true, force: true });
}

console.log("neovim-diff-preview-extension-spec-ok");
