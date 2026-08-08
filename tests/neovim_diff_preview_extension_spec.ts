import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { registerNeovimDiffPreview } from "../pi-extensions/neovim-diff-preview/index.js";

const tools: Array<Record<string, unknown>> = [];
const handlers = new Map<string, Function[]>();
const pi = {
  registerTool(tool: unknown) {
    tools.push(tool as Record<string, unknown>);
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
});

const toolCall = handlers.get("tool_call")?.[0];
assert(toolCall);
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
  const context = {
    cwd: directory,
    signal: undefined,
    ui: {
      notify(message: string) {
        notifications.push(message);
      },
    },
  };

  const gate = await toolCall(
    { toolName: "edit", toolCallId: "blocked-edit", input },
    context,
  );
  assert.equal(gate.block, true);
  assert(String(gate.reason).includes("Tighten unfolded_ranges"));
  assert.deepEqual(capturedProposal?.unfoldedRanges, input.unfolded_ranges);

  // Pi must not invoke the registered mutation tool after a blocked preflight.
  if (!gate.block) {
    const edit = tools.find((tool) => tool.name === "edit");
    assert(edit && typeof edit.execute === "function");
    await (edit.execute as Function)("blocked-edit", input, undefined, undefined, context);
  }
  assert.equal(await readFile(path, "utf8"), "before\n");
  assert.deepEqual(notifications, []);

  previewOutcome = "throw";
  const unavailable = await toolCall(
    { toolName: "edit", toolCallId: "unavailable-edit", input },
    context,
  );
  assert.equal(unavailable.block, true);
  assert(String(unavailable.reason).includes("edit/write call was not executed"));
  assert(notifications[0]?.includes("Neovim RPC disconnected"));
  assert.equal(await readFile(path, "utf8"), "before\n");

  previewOutcome = "success";
  const accepted = await toolCall(
    { toolName: "edit", toolCallId: "accepted-edit", input },
    context,
  );
  assert.equal(accepted, undefined);
  const edit = tools.find((tool) => tool.name === "edit");
  assert(edit && typeof edit.execute === "function");
  const mutationResult = await (edit.execute as Function)(
    "accepted-edit",
    input,
    undefined,
    undefined,
    context,
  );
  assert.equal(await readFile(path, "utf8"), "after\n");

  const toolResult = handlers.get("tool_result")?.[0];
  assert(toolResult);
  await toolResult(
    {
      toolName: "edit",
      toolCallId: "accepted-edit",
      input,
      isError: false,
      content: mutationResult.content,
      details: mutationResult.details,
    },
    context,
  );
  assert.deepEqual(refreshed, [path]);

  const executionEnd = handlers.get("tool_execution_end")?.[0];
  assert(executionEnd);
  await executionEnd({ toolName: "edit", toolCallId: "accepted-edit" }, context);
  assert.deepEqual(closed, ["accepted-edit"]);
} finally {
  await rm(directory, { recursive: true, force: true });
}

console.log("neovim-diff-preview-extension-spec-ok");
