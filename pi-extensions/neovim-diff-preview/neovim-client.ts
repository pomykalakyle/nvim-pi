import { attach } from "neovim";
import type { Proposal } from "./proposal.js";
import { isPreviewResult, type PreviewResult } from "./result.js";

export type NvimOperations = {
  openPreview: (proposal: Proposal) => Promise<PreviewResult>;
  refreshBuffer: (filePath: string) => Promise<void>;
  closePreview: (toolCallId: string) => Promise<void>;
  reloadPreview?: () => Promise<void>;
};

const silentLogger = {
  level: "silent",
  /** Reviewed: false. */
  info() {
    return this;
  },
  /** Reviewed: false. */
  warn() {
    return this;
  },
  /** Reviewed: false. */
  error() {
    return this;
  },
  /** Reviewed: false. */
  debug() {
    return this;
  },
};

/**
 * Execute Lua through the parent Neovim instance's MessagePack-RPC socket.
 * Reviewed: false.
 */
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

/**
 * Reload the Lua preview module after Pi's extension runtime reloads.
 * Reviewed: false.
 */
async function reloadPreview(): Promise<void> {
  await callNeovim(
    `
      local name = "config.pi.diff_preview"
      local loaded = package.loaded[name]
      if loaded and type(loaded.reload_if_idle) == "function" then
        return loaded.reload_if_idle()
      end
      if loaded and type(loaded.close) == "function" then
        pcall(loaded.close)
      end
      package.loaded[name] = nil
      require(name)
      return true
    `,
    [],
  );
}

/**
 * Send one proposal directly as structured MessagePack-RPC arguments.
 * Reviewed: false.
 */
async function openPreview(proposal: Proposal): Promise<PreviewResult> {
  const result = await callNeovim(
    'return require("config.pi.diff_preview").open(...)',
    [
      {
        requester_pid: process.pid,
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

/**
 * Refresh a loaded Neovim buffer after a file changes.
 * Reviewed: false.
 */
async function refreshBuffer(filePath: string): Promise<void> {
  await callNeovim('return require("config.pi.diff_preview").refresh(...)', [
    filePath,
  ]);
}

/**
 * Close a preview without making editor availability part of the decision.
 * Reviewed: false.
 */
async function closePreview(toolCallId: string): Promise<void> {
  try {
    await callNeovim('return require("config.pi.diff_preview").close(...)', [
      process.pid,
      toolCallId,
    ]);
  } catch {
    // A disappearing Neovim instance must not affect proposal state.
  }
}

export const defaultNvimOperations: NvimOperations = {
  openPreview,
  refreshBuffer,
  closePreview,
  reloadPreview,
};
