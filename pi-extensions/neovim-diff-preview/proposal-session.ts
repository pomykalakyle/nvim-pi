import { resolve } from "node:path";
import {
  type ExtensionAPI,
  type ExtensionContext,
  isEditToolResult,
  isToolCallEventType,
  isWriteToolResult,
} from "@earendil-works/pi-coding-agent";
import type {
  AuthorizerLog,
  PermissionsService,
  PromptPermissionDetails,
} from "@gotgenes/pi-permission-system";
import { Type } from "typebox";
import { getVibingModeService } from "../vibing-mode/shared.js";
import {
  defaultNvimOperations,
  type NvimOperations,
} from "./neovim-client.js";
import {
  persistPendingProposal,
  restorePendingProposal,
} from "./proposal-persistence.js";
import { formatPreviewFailure } from "./result.js";
import {
  absolutePath,
  applyProposal,
  buildEditProposal,
  buildWriteProposal,
  type Proposal,
} from "./proposal.js";
import { requestManualReview, type ReviewDecision } from "./review-ui.js";
import {
  type PreviewEditInput,
  type PreviewWriteInput,
  registerPreviewAwareMutationTools,
} from "./tools.js";

const PERMISSIONS_SERVICE_KEY = Symbol.for(
  "@gotgenes/pi-permission-system:service",
);
const PROPOSAL_AUTHORIZER = "neovim-diff-preview";

type CandidateProposal = {
  proposal: Proposal;
  previous: Proposal | undefined;
};

type ActivePreview = {
  toolCallId: string;
};

type AuthorizerService = Pick<PermissionsService, "registerAuthorizer">;
type SymbolRegistry = Record<symbol, unknown>;

/** Suppress only proposals covered by the active request capability. */
function shouldSuppressPreview(
  toolName: "edit" | "write",
  path: string,
): boolean {
  try {
    return (
      getVibingModeService()?.shouldSuppressPreview(toolName, path) === true
    );
  } catch {
    return false;
  }
}

function getPermissionsService(): AuthorizerService | undefined {
  const candidate = (globalThis as unknown as SymbolRegistry)[
    PERMISSIONS_SERVICE_KEY
  ];
  if (!candidate || typeof candidate !== "object") return undefined;
  const service = candidate as Partial<AuthorizerService>;
  return typeof service.registerAuthorizer === "function"
    ? (service as AuthorizerService)
    : undefined;
}

/** Register conversational edit/write proposals around Pi's real tools. */
export function registerProposalSession(
  pi: ExtensionAPI,
  nvimOperations: NvimOperations = defaultNvimOperations,
): void {
  let pending: Proposal | undefined;
  let candidate: CandidateProposal | undefined;
  let active: ActivePreview | undefined;
  let stopAfterProposal = false;
  let registeredPermissions: AuthorizerService | undefined;
  let disposeAuthorizer: (() => void) | undefined;

  const persistPending = (): void => {
    persistPendingProposal(pi, pending);
  };

  /** Tell the model about a proposal decision made outside its tool call. */
  const announceResolution = (
    resolved: Proposal,
    action: "accept" | "reject",
  ): void => {
    const resolution = action === "accept" ? "accepted" : "rejected";
    pi.sendMessage(
      {
        customType: "nvim-pi-proposal-resolution",
        content:
          action === "accept" ? "Proposal accepted." : "Proposal rejected.",
        display: true,
        details: {
          action: resolution,
          path: resolved.inputPath,
          toolName: resolved.toolName,
        },
      },
      { triggerTurn: true },
    );
  };

  /** Resolve the pending proposal and return the snapshot that was cleared. */
  const resolvePendingProposal = async (
    action: "accept" | "reject",
    ctx: ExtensionContext,
  ): Promise<Proposal | undefined> => {
    const resolved = pending;
    if (!resolved) return undefined;

    // Acceptance is valid only while the exact reviewed Neovim diff is active.
    if (action === "accept") {
      if (active?.toolCallId !== resolved.toolCallId) {
        throw new Error("The pending proposal has no active Neovim diff.");
      }
      await applyProposal(resolved);
    }

    // Both decisions clear active and persisted review state; transcript history remains.
    pending = undefined;
    candidate = undefined;
    active = undefined;
    persistPending();
    try {
      await nvimOperations.closePreview(resolved.toolCallId);
    } catch (error) {
      ctx.ui.notify(
        `The proposal was resolved, but Neovim could not close its preview: ${error instanceof Error ? error.message : String(error)}`,
        "warning",
      );
    }

    if (action === "accept") {
      try {
        await nvimOperations.refreshBuffer(resolved.filePath);
      } catch (error) {
        ctx.ui.notify(
          `The proposal was accepted, but Neovim could not refresh the file: ${error instanceof Error ? error.message : String(error)}`,
          "warning",
        );
      }
    }
    return resolved;
  };

  /** Open the focused review UI when the active Pi mode can render it. */
  const promptForPendingProposal = async (
    ctx: ExtensionContext,
  ): Promise<ReviewDecision> => {
    if (!pending || ctx.mode !== "tui") return "talk";
    return requestManualReview(ctx, {
      path: pending.inputPath,
      justification: pending.justification,
    });
  };

  const restorePreview = async (
    proposal: Proposal | undefined,
  ): Promise<boolean> => {
    if (!proposal) return false;
    active = undefined;
    try {
      const result = await nvimOperations.openPreview(proposal);
      if (!result.ok) return false;
      active = { toolCallId: proposal.toolCallId };
      return true;
    } catch {
      return false;
    }
  };

  const synchronizeSessionProposal = async (
    ctx: ExtensionContext,
  ): Promise<void> => {
    const priorActive = active;
    candidate = undefined;
    active = undefined;
    stopAfterProposal = false;
    if (priorActive) await nvimOperations.closePreview(priorActive.toolCallId);

    pending = restorePendingProposal(ctx);
    if (pending && resolve(ctx.cwd) !== resolve(pending.cwd)) {
      pending = undefined;
      persistPending();
      ctx.ui.notify(
        "A pending proposal from another working directory was discarded. Ask the model to propose it again in this worktree.",
        "warning",
      );
    }

    if (pending && !(await restorePreview(pending))) {
      ctx.ui.notify(
        "The pending proposal was restored, but its Neovim diff is unavailable. Revise or reject it before accepting.",
        "warning",
      );
    }
  };

  const registerAuthorizer = (): boolean => {
    const permissions = getPermissionsService();
    if (!permissions) return false;
    if (registeredPermissions === permissions && disposeAuthorizer) return true;

    try {
      disposeAuthorizer?.();
    } catch {
      // Ignore a stale generation's disposer during reload.
    }
    registeredPermissions = undefined;
    disposeAuthorizer = undefined;

    try {
      disposeAuthorizer = permissions.registerAuthorizer(
        PROPOSAL_AUTHORIZER,
        async (
          details: PromptPermissionDetails,
          _query: unknown,
          log: AuthorizerLog,
        ) => {
          const staged = candidate?.proposal;
          if (
            !staged ||
            details.source !== "tool_call" ||
            details.forwarding !== undefined ||
            details.toolCallId !== staged.toolCallId ||
            details.toolName !== staged.toolName
          ) {
            return { kind: "defer" } as const;
          }
          const requestedPath =
            details.path ??
            details.accessIntent?.boundaryValue ??
            details.accessIntent?.matchValues[0];
          if (typeof requestedPath !== "string") {
            return { kind: "defer" } as const;
          }
          const authorizedPath = absolutePath(staged.cwd, requestedPath);
          if (
            authorizedPath !== staged.filePath &&
            authorizedPath !== staged.mutationPath
          ) {
            return { kind: "defer" } as const;
          }

          log.review("neovim_diff_preview.proposal_allow", {
            requestId: details.requestId,
            toolName: details.toolName,
            path: staged.filePath,
          });
          return { kind: "allow" } as const;
        },
      );
      registeredPermissions = permissions;
      return true;
    } catch {
      return false;
    }
  };

  registerPreviewAwareMutationTools(
    pi,
    shouldSuppressPreview,
    async (toolCallId, _toolName, _input, ctx) => {
      if (!candidate || candidate.proposal.toolCallId !== toolCallId)
        return undefined;
      pending = candidate.proposal;
      candidate = undefined;
      stopAfterProposal = true;
      persistPending();

      // Persist first so choosing Talk can hand the same proposal to conversation.
      const decision = await promptForPendingProposal(ctx);
      if (decision !== "talk") {
        try {
          const resolved = await resolvePendingProposal(decision, ctx);
          if (resolved) {
            const resolution = decision === "accept" ? "accepted" : "rejected";
            return {
              content: [
                {
                  type: "text",
                  text: `Proposal ${resolution}: ${resolved.inputPath}`,
                },
              ],
              details: {
                proposalResolution: resolution,
                path: resolved.inputPath,
                toolName: resolved.toolName,
              },
            };
          }
        } catch (error) {
          // A failed acceptance remains pending so the user can revise or reject it.
          ctx.ui.notify(
            error instanceof Error ? error.message : String(error),
            "error",
          );
        }
      }

      const discussing = pending;
      if (!discussing) {
        throw new Error("The proposal disappeared before review completed.");
      }
      return {
        content: [
          {
            type: "text",
            text: `Proposal pending for ${discussing.inputPath}. The file has not changed. Return control to the user so they can discuss it, revise it, or press Option+R to review it again.`,
          },
        ],
        details: {
          proposalPending: true,
          path: discussing.inputPath,
          toolName: discussing.toolName,
        },
        terminate: true,
      };
    },
  );

  const unsubscribePermissionsReady = pi.events.on(
    "permissions:ready",
    registerAuthorizer,
  );

  pi.registerCommand("proposal", {
    description: "Accept or reject the current edit/write proposal",
    getArgumentCompletions(prefix) {
      return ["accept", "reject"]
        .filter((value) => value.startsWith(prefix))
        .map((value) => ({ value, label: value }));
    },
    handler: async (args, ctx) => {
      await ctx.waitForIdle();
      const action = args.trim().toLowerCase();
      if (action !== "accept" && action !== "reject") {
        ctx.ui.notify("Usage: /proposal accept or /proposal reject", "info");
        return;
      }
      if (!pending) {
        ctx.ui.notify("There is no pending proposal.", "info");
        return;
      }

      let resolved: Proposal | undefined;
      try {
        resolved = await resolvePendingProposal(action, ctx);
      } catch (error) {
        ctx.ui.notify(
          error instanceof Error ? error.message : String(error),
          "error",
        );
        return;
      }
      if (!resolved) {
        ctx.ui.notify("There is no pending proposal.", "info");
        return;
      }

      ctx.ui.notify(
        `${action === "accept" ? "Accepted" : "Rejected"} proposal for ${resolved.inputPath}.`,
        "info",
      );

      announceResolution(resolved, action);
    },
  });

  pi.registerShortcut("alt+r", {
    description: "Review pending file proposal",
    handler: async (ctx) => {
      if (!pending) {
        ctx.ui.notify("There is no pending proposal.", "info");
        return;
      }
      // Do not let a shortcut race an active model turn or tool batch.
      if (!ctx.isIdle()) {
        ctx.ui.notify("Wait for Pi to finish before reviewing the proposal.", "info");
        return;
      }

      const decision = await promptForPendingProposal(ctx);
      if (decision === "talk") return;
      try {
        const resolved = await resolvePendingProposal(decision, ctx);
        if (!resolved) return;
        ctx.ui.notify(
          `${decision === "accept" ? "Accepted" : "Rejected"} proposal for ${resolved.inputPath}.`,
          "info",
        );
        announceResolution(resolved, decision);
      } catch (error) {
        ctx.ui.notify(
          error instanceof Error ? error.message : String(error),
          "error",
        );
      }
    },
  });

  pi.registerTool({
    name: "resolve_proposal",
    label: "Resolve proposal",
    description:
      "Accept or reject the pending file proposal. Use only when the user clearly asks to accept/apply or reject/discard it.",
    parameters: Type.Object({
      action: Type.Union([Type.Literal("accept"), Type.Literal("reject")]),
    }),
    async execute(_toolCallId, input, _signal, _onUpdate, ctx) {
      const resolved = await resolvePendingProposal(input.action, ctx);
      if (!resolved) {
        return {
          content: [{ type: "text", text: "There is no pending proposal." }],
          details: undefined,
        };
      }
      return {
        content: [
          {
            type: "text",
            text: `Proposal ${input.action === "accept" ? "accepted" : "rejected"}: ${resolved.inputPath}`,
          },
        ],
        details: { action: input.action, path: resolved.inputPath },
      };
    },
  });

  pi.on("session_start", async (_event, ctx) => {
    try {
      await nvimOperations.reloadPreview?.();
    } catch (error) {
      ctx.ui.notify(
        `Pi diff preview could not reload its Neovim runtime: ${error instanceof Error ? error.message : String(error)}`,
        "warning",
      );
    }
    await synchronizeSessionProposal(ctx);
    registerAuthorizer();
  });

  pi.on("session_tree", async (_event, ctx) => {
    await synchronizeSessionProposal(ctx);
  });

  pi.on("before_agent_start", (event) => {
    if (!pending) return;
    return {
      systemPrompt: `${event.systemPrompt}\n\nA file proposal is pending for ${pending.inputPath}. The file on disk is still unchanged. This conversation is scoped to reviewing that proposal, but answer any codebase questions the user needs in order to evaluate it. You may read and search freely. Use edit or write only on that same path to replace the proposal in place. Do not run tests, bash commands, or unrelated mutations until the user accepts or rejects the proposal. If the user clearly accepts or rejects it in conversation, call resolve_proposal with that action; do not infer resolution from ambiguous feedback.`,
    };
  });

  pi.on("turn_end", (_event, ctx) => {
    if (!stopAfterProposal) return;
    stopAfterProposal = false;
    ctx.abort();
  });

  // Build and display edit/write proposals before the permission system runs.
  pi.on("tool_call", async (event, ctx) => {
    if ((pending || candidate) && event.toolName === "bash") {
      return {
        block: true,
        reason:
          "A file proposal is pending. Bash commands and tests are available after /proposal accept or /proposal reject.",
      };
    }
    if (
      !isToolCallEventType("edit", event) &&
      !isToolCallEventType("write", event)
    ) {
      return;
    }
    if (shouldSuppressPreview(event.toolName, event.input.path)) return;
    if (candidate) {
      return {
        block: true,
        reason:
          "Only one edit/write proposal can be prepared at a time. Return control to the user before revising it.",
      };
    }

    const filePath = absolutePath(ctx.cwd, event.input.path);
    if (pending && pending.filePath !== filePath) {
      return {
        block: true,
        reason: `A proposal for ${pending.inputPath} is already pending. Revise that file or ask the user to accept or reject it first.`,
      };
    }

    const previous = pending;
    try {
      const proposal = isToolCallEventType<"edit", PreviewEditInput>(
        "edit",
        event,
      )
        ? await buildEditProposal(event.toolCallId, event.input, ctx)
        : await buildWriteProposal(
            event.toolCallId,
            event.input as PreviewWriteInput,
            ctx.cwd,
          );
      active = undefined;
      const result = await nvimOperations.openPreview(proposal);
      if (result.ok === false) {
        await restorePreview(previous);
        return { block: true, reason: formatPreviewFailure(result) };
      }
      candidate = { proposal, previous };
      active = { toolCallId: proposal.toolCallId };
      if (!registerAuthorizer()) {
        ctx.ui.notify(
          "The proposal authorizer is unavailable; normal permission review may appear.",
          "warning",
        );
      }
    } catch (error) {
      await restorePreview(previous);
      const message = `Pi diff preview unavailable: ${error instanceof Error ? error.message : String(error)}`;
      ctx.ui.notify(message, "warning");
      return {
        block: true,
        reason: `${message}. The edit/write call was not executed; correct the preview request or restore Neovim and retry.`,
      };
    }
  });

  // Refresh only real immediate mutations, such as request-scoped Vibing Mode.
  pi.on("tool_result", async (event, ctx) => {
    if (
      event.isError ||
      (event.details as { proposalPending?: unknown } | undefined)
        ?.proposalPending === true ||
      (!isEditToolResult(event) && !isWriteToolResult(event)) ||
      typeof event.input.path !== "string"
    ) {
      return;
    }

    const filePath = absolutePath(ctx.cwd, event.input.path);
    try {
      await nvimOperations.refreshBuffer(filePath);
    } catch (error) {
      ctx.ui.notify(
        `Neovim buffer refresh unavailable: ${error instanceof Error ? error.message : String(error)}`,
        "warning",
      );
    }
  });

  // Keep a promoted proposal open; clean up rejected or failed candidates.
  pi.on("tool_execution_end", async (event) => {
    if (!active || active.toolCallId !== event.toolCallId) return;
    if (pending?.toolCallId === event.toolCallId) return;

    const staged =
      candidate?.proposal.toolCallId === event.toolCallId
        ? candidate
        : undefined;
    candidate = undefined;
    active = undefined;
    await nvimOperations.closePreview(event.toolCallId);
    await restorePreview(staged?.previous);
  });

  pi.on("session_shutdown", async () => {
    if (active) await nvimOperations.closePreview(active.toolCallId);
    candidate = undefined;
    active = undefined;
    unsubscribePermissionsReady();
    disposeAuthorizer?.();
    disposeAuthorizer = undefined;
    registeredPermissions = undefined;
  });
}

export default registerProposalSession;
