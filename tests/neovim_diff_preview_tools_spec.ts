import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { registerPreviewAwareMutationTools } from "../pi-extensions/neovim-diff-preview/tools.js";

const tools: Array<Record<string, unknown>> = [];
registerPreviewAwareMutationTools({
  registerTool(tool: unknown) {
    tools.push(tool as Record<string, unknown>);
  },
} as unknown as ExtensionAPI);

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
