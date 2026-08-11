import { isAbsolute, resolve } from "node:path";
import { attach } from "neovim";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import {
  formatFocusFailure,
  isFocusResult,
  type FocusResult,
} from "./result.js";

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

let focusQueue: Promise<void> = Promise.resolve();

/**
 * Serialize editor focus calls because Pi may execute sibling tool calls concurrently.
 * Reviewed: false.
 */
function enqueueFocus<T>(operation: () => Promise<T>): Promise<T> {
  const result = focusQueue.then(operation, operation);
  focusQueue = result.then(
    /** Reviewed: false. */ () => undefined,
    /** Reviewed: false. */ () => undefined,
  );
  return result;
}

/**
 * Resolve a tool path against Pi's working directory and normalize @-prefixed inputs.
 * Reviewed: false.
 */
function absolutePath(cwd: string, path: string): string {
  const normalized = path.startsWith("@") ? path.slice(1) : path;
  return isAbsolute(normalized) ? resolve(normalized) : resolve(cwd, normalized);
}

/**
 * Execute Lua through the parent Neovim instance's MessagePack-RPC socket.
 * Reviewed: false.
 */
async function callNeovim(code: string, args: unknown[]): Promise<unknown> {
  const socket = process.env.NVIM;
  if (!socket) throw new Error("Neovim socket address is unavailable");

  const nvim = attach({ socket, options: { logger: silentLogger } });
  try {
    return await nvim.request("nvim_exec_lua", [code, args]);
  } finally {
    await nvim.close();
  }
}

/**
 * Ask Neovim to focus an inclusive file range beside this exact Pi process.
 * Reviewed: false.
 */
async function focusFile(
  cwd: string,
  path: string,
  startLine: number,
  endLine: number,
): Promise<FocusResult> {
  const result = await callNeovim(
    'return require("config.pi.file_focus").focus(...)',
    [{
      requester_pid: process.pid,
      file_path: absolutePath(cwd, path),
      start_line: startLine,
      end_line: endLine,
    }],
  );

  if (!isFocusResult(result)) {
    throw new Error("Neovim returned an invalid focus_file result");
  }
  return result;
}

/**
 * Remove temporary focus styling when this Pi session shuts down or reloads.
 * Reviewed: false.
 */
async function clearFileFocus(): Promise<void> {
  await callNeovim(
    'return require("config.pi.file_focus").clear(...)',
    [process.pid],
  );
}

/**
 * Register the agent-facing tool while Neovim retains all layout authority.
 * Reviewed: false.
 */
export default function neovimFileFocus(pi: ExtensionAPI): void {
  pi.registerTool({
    name: "focus_file",
    label: "Focus File",
    description:
      "Focus an inclusive line range in Neovim by dimming the rest. Normally fits 84 rows; live fit is checked.",
    promptSnippet: "Focus an inclusive line range in Neovim",
    parameters: Type.Object({
      path: Type.String({ description: "File path, relative to the working directory or absolute" }),
      start_line: Type.Integer({ minimum: 1, description: "First line to focus, inclusive" }),
      end_line: Type.Integer({ minimum: 1, description: "Last line to focus, inclusive" }),
    }),
    /** Reviewed: false. */
    async execute(_toolCallId, params, signal, onUpdate, ctx) {
      if (signal?.aborted) throw new Error("focus_file was cancelled");

      onUpdate?.({
        content: [{ type: "text", text: `Focusing ${params.path}:${params.start_line}-${params.end_line}…` }],
        details: {},
      });

      const result = await enqueueFocus(/** Reviewed: false. */ () =>
        focusFile(ctx.cwd, params.path, params.start_line, params.end_line)
      );
      if (result.ok === false) throw new Error(formatFocusFailure(result));

      return {
        content: [{
          type: "text",
          text:
            `Focused ${params.path}:${result.start_line}-${result.end_line} in Neovim `
            + `(${result.range_rows} of ${result.viewport_rows} displayed rows).`,
        }],
        details: result,
      };
    },
  });

  pi.on("session_shutdown", /** Reviewed: false. */ () => {
    void clearFileFocus().catch(/** Reviewed: false. */ () => {
      // A disappearing Neovim instance must not interfere with Pi shutdown.
    });
  });
}
