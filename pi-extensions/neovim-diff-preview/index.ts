import { constants } from "node:fs";
import { access, readFile } from "node:fs/promises";
import { isAbsolute, resolve } from "node:path";
import { attach } from "neovim";
import {
  createEditToolDefinition,
  isEditToolResult,
  isToolCallEventType,
  isWriteToolResult,
  type ExtensionAPI,
  type ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import { getVibingModeService } from "../vibing-mode/shared.js";
import {
  formatPreviewFailure,
  isPreviewResult,
  type PreviewResult,
} from "./result.js";
import {
  registerPreviewAwareMutationTools,
  type PreviewEditInput,
  type PreviewWriteInput,
  type UnfoldedRange,
} from "./tools.js";

const silentLogger = {
  level: "silent",
  info() {
    return this;
  },
  warn() {
    return this;
  },
  error() {
    return this;
  },
  debug() {
    return this;
  },
};

type Proposal = {
  toolCallId: string;
  toolName: "edit" | "write";
  filePath: string;
  oldContent: string;
  newContent: string;
  unfoldedRanges: UnfoldedRange[];
};
type ActivePreview = {
  toolCallId: string;
};

type PreviewDependencies = {
  openPreview: (proposal: Proposal) => Promise<PreviewResult>;
  refreshBuffer: (filePath: string) => Promise<void>;
  closePreview: (toolCallId: string) => Promise<void>;
};

/** Suppress only proposals covered by the active request capability. */
function shouldSuppressPreview(toolName: "edit" | "write", path: string): boolean {
  try {
    return getVibingModeService()?.shouldSuppressPreview(toolName, path) === true;
  } catch {
    return false;
  }
}

/** Resolve a tool path against Pi's working directory.
 * Preserve absolute inputs while normalizing both path forms. */
function absolutePath(cwd: string, path: string): string {
  return isAbsolute(path) ? resolve(path) : resolve(cwd, path);
}

/** Run Pi's real edit implementation while capturing its write in memory.
 * This keeps preview semantics identical without changing the target file. */
async function buildEditProposal(
  toolCallId: string,
  input: PreviewEditInput,
  ctx: ExtensionContext,
): Promise<Proposal> {
  let oldContent: string | undefined;
  let newContent: string | undefined;
  const previewTool = createEditToolDefinition(ctx.cwd, {
    operations: {
      access: (path) => access(path, constants.R_OK | constants.W_OK),
      readFile: async (path) => {
        const content = await readFile(path);
        oldContent = content.toString("utf8");
        return content;
      },
      writeFile: async (_path, content) => {
        newContent = content;
      },
    },
  });

  await previewTool.execute(toolCallId, input, ctx.signal, undefined, ctx);
  if (oldContent === undefined || newContent === undefined) {
    throw new Error("Pi edit preview did not produce file contents");
  }

  return {
    toolCallId,
    toolName: "edit",
    filePath: absolutePath(ctx.cwd, input.path),
    oldContent,
    newContent,
    unfoldedRanges: input.unfolded_ranges,
  };
}

/** Build a full-content write proposal from Pi's validated input.
 * Treat only a missing target as a new file with empty original contents. */
async function buildWriteProposal(
  toolCallId: string,
  input: PreviewWriteInput,
  cwd: string,
): Promise<Proposal> {
  const filePath = absolutePath(cwd, input.path);
  let oldContent = "";
  try {
    oldContent = await readFile(filePath, "utf8");
  } catch (error) {
    if (
      !error ||
      typeof error !== "object" ||
      !("code" in error) ||
      error.code !== "ENOENT"
    ) {
      throw error;
    }
  }

  return {
    toolCallId,
    toolName: "write",
    filePath,
    oldContent,
    newContent: input.content,
    unfoldedRanges: input.unfolded_ranges,
  };
}

/** Execute Lua through the parent Neovim instance's MessagePack-RPC socket.
 * Close the short-lived client after its response arrives. */
async function callNeovim(code: string, args: unknown[]): Promise<unknown> {
  const socket = process.env.NVIM;
  if (!socket) throw new Error("NVIM socket address is unavailable");
  const nvim = attach({ socket, options: { logger: silentLogger } });
  try {
    return await nvim.request("nvim_exec_lua", [code, args]);
  } finally {
    await nvim.close();
  }
}

/** Send one proposal directly as structured MessagePack-RPC arguments.
 * Neovim decodes the map into the Lua table consumed by M.open(). */
async function openPreview(proposal: Proposal): Promise<PreviewResult> {
  const result = await callNeovim(
    'return require("config.pi.diff_preview").open(...)',
    [
      {
        tool_call_id: proposal.toolCallId,
        file_path: proposal.filePath,
        old_content: proposal.oldContent,
        new_content: proposal.newContent,
        unfolded_ranges: proposal.unfoldedRanges,
      },
    ],
  );
  if (!isPreviewResult(result)) {
    throw new Error("Neovim returned an invalid diff preview result");
  }
  return result;
}

/** Refresh a loaded Neovim buffer after Pi successfully changes its file. */
async function refreshBuffer(filePath: string): Promise<void> {
  await callNeovim(
    'return require("config.pi.diff_preview").refresh(...)',
    [filePath],
  );
}

/** Ask Neovim to close the preview belonging to a completed tool call.
 * Ignore a vanished editor because it must not alter Pi's decision. */
async function closePreview(toolCallId: string): Promise<void> {
  try {
    await callNeovim(
      'return require("config.pi.diff_preview").close(...)',
      [toolCallId],
    );
  } catch {
    // A disappearing Neovim instance must not affect Pi's permission decision.
  }
}

/** Register proposal display and cleanup handlers around Pi tool execution.
 * Neovim remains display-only; Gotgenes independently owns approval. */
export function registerNeovimDiffPreview(
  pi: ExtensionAPI,
  dependencies: PreviewDependencies = { openPreview, refreshBuffer, closePreview },
): void {
  registerPreviewAwareMutationTools(pi, shouldSuppressPreview);
  let active: ActivePreview | undefined;

  // Build and display edit/write proposals before later handlers run.
  // Oversized proposals are blocked before the underlying tool executes.
  pi.on("tool_call", async (event, ctx) => {
    if (
      !isToolCallEventType("edit", event) &&
      !isToolCallEventType("write", event)
    ) {
      return;
    }
    if (shouldSuppressPreview(event.toolName, event.input.path)) return;

    try {
      const proposal = isToolCallEventType<"edit", PreviewEditInput>("edit", event)
        ? await buildEditProposal(event.toolCallId, event.input, ctx)
        : await buildWriteProposal(
          event.toolCallId,
          event.input as PreviewWriteInput,
          ctx.cwd,
        );
      const result = await dependencies.openPreview(proposal);
      if (result.ok === false) {
        return { block: true, reason: formatPreviewFailure(result) };
      }
      active = { toolCallId: proposal.toolCallId };
    } catch (error) {
      const message = `Pi diff preview unavailable: ${error instanceof Error ? error.message : String(error)}`;
      ctx.ui.notify(message, "warning");
      return {
        block: true,
        reason: `${message}. The edit/write call was not executed; correct the preview request or restore Neovim and retry.`,
      };
    }
  });

  // Refresh successful edit/write targets independently of preview display.
  // This also covers Vibing Mode and previews that could not be opened.
  pi.on("tool_result", async (event, ctx) => {
    if (
      event.isError
      || (!isEditToolResult(event) && !isWriteToolResult(event))
      || typeof event.input.path !== "string"
    ) {
      return;
    }

    const filePath = absolutePath(ctx.cwd, event.input.path);
    try {
      await dependencies.refreshBuffer(filePath);
    } catch (error) {
      ctx.ui.notify(
        `Neovim buffer refresh unavailable: ${error instanceof Error ? error.message : String(error)}`,
        "warning",
      );
    }
  });

  // Close the preview after Pi finalizes an approved, rejected, or failed call.
  // Pi emits this event even when permission handling blocks execution.
  pi.on("tool_execution_end", (event) => {
    if (!active || active.toolCallId !== event.toolCallId) return;
    const toolCallId = active.toolCallId;
    active = undefined;
    void dependencies.closePreview(toolCallId);
  });

  // Close any preview still waiting when this Pi process exits or reloads.
  // Clearing active state prevents later cleanup from targeting a stale call.
  pi.on("session_shutdown", () => {
    if (active) void dependencies.closePreview(active.toolCallId);
    active = undefined;
  });
}

export default registerNeovimDiffPreview;
