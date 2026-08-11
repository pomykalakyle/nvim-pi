import { rm } from "node:fs/promises";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import type { ManagedWorktree } from "./git.js";

type PendingHandoff = {
  sessionFile: string;
  worktree: ManagedWorktree;
};

export type HandoffDependencies = {
  createWorktree(
    cwd: string,
    requested: string,
    signal?: AbortSignal,
  ): Promise<ManagedWorktree>;
  rollbackWorktree(worktree: ManagedWorktree): Promise<void>;
  forkSession(source: string, targetCwd: string): string;
  openSession(worktree: string, sessionFile: string): Promise<void>;
};

/**
 * Register natural-language managed worktree handoffs for embedded Pi.
 * Reviewed: false.
 */
export function registerWorktreeHandoff(
  pi: ExtensionAPI,
  dependencies: HandoffDependencies,
): void {
  let pending: PendingHandoff | undefined;

  pi.registerTool({
    name: "create_worktree_handoff",
    label: "Create Worktree Handoff",
    description:
      "Create a managed Git worktree from origin/main and fork the current Pi conversation into it after this turn settles.",
    promptSnippet: "Create a managed worktree and continue this conversation there",
    promptGuidelines: [
      "Use create_worktree_handoff only when the user explicitly asks to move or continue the current task in a new worktree.",
      "Choose a concise lowercase task-relevant name for create_worktree_handoff.",
    ],
    parameters: Type.Object({
      name: Type.String({
        pattern: "^[a-z0-9][a-z0-9._-]*$",
        description: "Concise lowercase branch and worktree name",
      }),
    }),
    /** Reviewed: false. */
    async execute(_toolCallId, params, signal, onUpdate, ctx) {
      if (signal?.aborted) throw new Error("Worktree handoff was cancelled");
      if (pending) throw new Error("A worktree handoff is already pending");

      const sessionFile = ctx.sessionManager.getSessionFile();
      if (!sessionFile) throw new Error("The current Pi session is not persisted and cannot be forked");

      onUpdate?.({
        content: [{ type: "text", text: `Creating worktree ${params.name}…` }],
        details: {},
      });
      const worktree = await dependencies.createWorktree(ctx.cwd, params.name, signal);
      if (signal?.aborted) {
        await dependencies.rollbackWorktree(worktree);
        throw new Error("Worktree handoff was cancelled");
      }
      pending = { sessionFile, worktree };

      return {
        content: [{
          type: "text",
          text: `Created ${worktree.branch} at ${worktree.path}. The conversation will continue there.`,
        }],
        details: worktree,
        terminate: true,
      };
    },
  });

  pi.on("agent_settled", /** Reviewed: false. */ async (_event, ctx) => {
    const handoff = pending;
    pending = undefined;
    if (!handoff) return;

    let forkedSession: string | undefined;
    try {
      forkedSession = dependencies.forkSession(handoff.sessionFile, handoff.worktree.path);
      await dependencies.openSession(handoff.worktree.path, forkedSession);
    } catch (error) {
      const failures = [error instanceof Error ? error.message : String(error)];
      if (forkedSession) {
        await rm(forkedSession, { force: true }).catch(/** Reviewed: false. */ (cleanupError) => {
          failures.push(`Session cleanup failed: ${String(cleanupError)}`);
        });
      }
      await dependencies.rollbackWorktree(handoff.worktree).catch(/** Reviewed: false. */ (cleanupError) => {
        failures.push(cleanupError instanceof Error ? cleanupError.message : String(cleanupError));
      });
      ctx.ui.notify(`Worktree handoff failed: ${failures.join(" ")}`, "error");
    }
  });
}
