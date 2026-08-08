import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { registerPreviewAwareMutationTools } from "../pi-extensions/neovim-diff-preview/tools.js";

const tools: Array<Record<string, unknown>> = [];
let terminalDiffEnabled = false;
registerPreviewAwareMutationTools({
  registerTool(tool: unknown) {
    tools.push(tool as Record<string, unknown>);
  },
} as unknown as ExtensionAPI, () => terminalDiffEnabled);

assert.deepEqual(tools.map((tool) => tool.name), ["edit", "write"]);
for (const tool of tools) {
  const parameters = tool.parameters as { required?: string[]; properties?: Record<string, unknown> };
  assert(parameters.required?.includes("unfolded_ranges"));
  assert(parameters.properties?.unfolded_ranges);
  assert(String(tool.description).includes("proposed file"));
  assert(String(tool.description).toLowerCase().includes("every changed hunk"));
  assert.equal(typeof tool.prepareArguments, "function");
  assert.throws(
    () => (tool.prepareArguments as Function)({
      path: "example.txt",
      edits: [{ oldText: "before", newText: "after" }],
      content: "after",
      unfolded_ranges: [{ start_line: 3, end_line: 2 }],
    }),
    /end_line greater than or equal to start_line/,
  );
}

const theme = {
  bold: (text: string) => text,
  fg: (_color: string, text: string) => text,
  bg: (_color: string, text: string) => text,
};
function renderContext(args: unknown, state: Record<string, unknown> = {}) {
  return {
    args,
    state,
    lastComponent: undefined,
    invalidate() {},
    toolCallId: "render-test",
    cwd: process.cwd(),
    executionStarted: false,
    argsComplete: true,
    isPartial: false,
    expanded: true,
    showImages: false,
    isError: false,
  };
}

const editRenderer = tools.find((tool) => tool.name === "edit")!;
const editArgs = {
  path: "example.txt",
  edits: [{ oldText: "terminal-old", newText: "terminal-new" }],
  unfolded_ranges: [{ start_line: 1, end_line: 1 }],
};
const compactEditContext = renderContext(editArgs);
const compactEdit = (editRenderer.renderCall as Function)(
  editArgs,
  theme,
  compactEditContext,
);
assert(!compactEdit.render(80).join("\n").includes("terminal-new"));
assert.equal(compactEditContext.state.terminalRenderer, "compact");

const writeRenderer = tools.find((tool) => tool.name === "write")!;
const writeArgs = {
  path: "example.txt",
  content: "terminal-content",
  unfolded_ranges: [{ start_line: 1, end_line: 1 }],
};
const compactWriteContext = renderContext(writeArgs);
const compactWrite = (writeRenderer.renderCall as Function)(
  writeArgs,
  theme,
  compactWriteContext,
);
assert(!compactWrite.render(80).join("\n").includes("terminal-content"));
assert.equal(compactWriteContext.state.terminalRenderer, "compact");

const compactError = (writeRenderer.renderResult as Function)(
  { content: [{ type: "text", text: "write exploded" }] },
  {},
  theme,
  { ...compactWriteContext, isError: true },
);
assert(compactError.render(80).join("\n").includes("write exploded"));

terminalDiffEnabled = true;
const nativeWriteContext = renderContext(writeArgs);
const nativeWrite = (writeRenderer.renderCall as Function)(
  writeArgs,
  theme,
  nativeWriteContext,
);
assert(nativeWrite.render(80).join("\n").includes("terminal-content"));
assert.equal(nativeWriteContext.state.terminalRenderer, "native");

// Keep the per-call choice stable if the request-scoped capability settles
// before Pi performs its final result render.
terminalDiffEnabled = false;
nativeWriteContext.lastComponent = nativeWrite;
const settledNativeWrite = (writeRenderer.renderCall as Function)(
  writeArgs,
  theme,
  nativeWriteContext,
);
assert(settledNativeWrite.render(80).join("\n").includes("terminal-content"));

const fallbackTools: Array<Record<string, unknown>> = [];
registerPreviewAwareMutationTools({
  registerTool(tool: unknown) {
    fallbackTools.push(tool as Record<string, unknown>);
  },
} as unknown as ExtensionAPI, () => {
  throw new Error("stale Vibing Mode service");
});
const fallbackWrite = fallbackTools.find((tool) => tool.name === "write")!;
const fallbackContext = renderContext(writeArgs);
const safeFallback = (fallbackWrite.renderCall as Function)(writeArgs, theme, fallbackContext);
assert(!safeFallback.render(80).join("\n").includes("terminal-content"));
assert.equal(fallbackContext.state.terminalRenderer, "compact");

const directory = await mkdtemp(join(tmpdir(), "nvim-pi-preview-tools-"));
try {
  const context = { cwd: directory };
  const editPath = join(directory, "edit.txt");
  await writeFile(editPath, "before\n", "utf8");
  const edit = tools.find((tool) => tool.name === "edit");
  assert(edit && typeof edit.execute === "function");
  await (edit.execute as Function)(
    "edit-test",
    {
      path: "edit.txt",
      edits: [{ oldText: "before", newText: "after" }],
      unfolded_ranges: [{ start_line: 1, end_line: 1 }],
    },
    undefined,
    undefined,
    context,
  );
  assert.equal(await readFile(editPath, "utf8"), "after\n");

  const write = tools.find((tool) => tool.name === "write");
  assert(write && typeof write.execute === "function");
  await (write.execute as Function)(
    "write-test",
    {
      path: "write.txt",
      content: "written\n",
      unfolded_ranges: [{ start_line: 1, end_line: 1 }],
    },
    undefined,
    undefined,
    context,
  );
  assert.equal(await readFile(join(directory, "write.txt"), "utf8"), "written\n");
} finally {
  await rm(directory, { recursive: true, force: true });
}

console.log("neovim-diff-preview-tools-spec-ok");
