import {
  SessionManager,
  type ExtensionAPI,
} from "@earendil-works/pi-coding-agent";
import {
  createManagedWorktree,
  rollbackManagedWorktree,
} from "./git.js";
import {
  registerWorktreeHandoff,
  type HandoffDependencies,
} from "./extension.js";
import {
  acknowledgeWorktreeHandoff,
  openWorktreeSession,
} from "./neovim.js";

const dependencies: HandoffDependencies = {
  createWorktree: createManagedWorktree,
  rollbackWorktree: rollbackManagedWorktree,
  /** Provenance: vibed=true, reviewed=false. */
  forkSession(source, targetCwd) {
    const session = SessionManager.forkFrom(source, targetCwd);
    const file = session.getSessionFile();
    if (!file) throw new Error("Pi did not create a persisted forked session");
    return file;
  },
  openSession: openWorktreeSession,
};

/**
 * Register natural-language managed worktree handoffs for embedded Pi.
 * Provenance: vibed=true, reviewed=false.
 */
export default function worktreeHandoff(pi: ExtensionAPI): void {
  registerWorktreeHandoff(pi, dependencies);
  pi.on("session_start", /** Provenance: vibed=true, reviewed=false. */ async () => {
    const token = process.env.PI_NVIM_HANDOFF_ID;
    delete process.env.PI_NVIM_HANDOFF_ID;
    if (token) await acknowledgeWorktreeHandoff(token);
  });
}
