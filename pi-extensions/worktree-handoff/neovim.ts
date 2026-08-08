import { attach } from "neovim";

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

type HandoffResult = {
  ok: boolean;
  error?: string;
  worktree?: string;
};

/** Tell the parent Neovim instance that the handed-off Pi session is ready. */
export async function acknowledgeWorktreeHandoff(token: string): Promise<void> {
  const socket = process.env.NVIM;
  if (!socket) throw new Error("Neovim socket address is unavailable");

  const nvim = attach({ socket, options: { logger: silentLogger as never } });
  try {
    const acknowledged = await nvim.request("nvim_exec_lua", [
      'return require("config.pi.worktree").acknowledge_handoff(...)',
      [token],
    ]);
    if (acknowledged !== true) throw new Error("Neovim rejected the worktree startup acknowledgment");
  } finally {
    await nvim.close();
  }
}

/** Ask the parent Neovim instance to open a prepared Pi session. */
export async function openWorktreeSession(worktree: string, sessionFile: string): Promise<void> {
  const socket = process.env.NVIM;
  if (!socket) throw new Error("Neovim socket address is unavailable");

  const nvim = attach({ socket, options: { logger: silentLogger as never } });
  try {
    const value = await nvim.request("nvim_exec_lua", [
      'return require("config.pi.worktree").handoff(...)',
      [{ worktree, session_file: sessionFile }],
    ]);
    if (!value || typeof value !== "object" || !("ok" in value)) {
      throw new Error("Neovim returned an invalid worktree handoff result");
    }
    const result = value as HandoffResult;
    if (!result.ok) throw new Error(result.error || "Neovim rejected the worktree handoff");
  } finally {
    await nvim.close();
  }
}
