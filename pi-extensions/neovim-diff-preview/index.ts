import { constants } from "node:fs";
import { access, open, readFile, realpath, stat } from "node:fs/promises";
import { basename, dirname, isAbsolute, resolve } from "node:path";
import {
  createEditToolDefinition,
  type ExtensionAPI,
  type ExtensionContext,
  isEditToolResult,
  isToolCallEventType,
  isWriteToolResult,
  withFileMutationQueue,
} from "@earendil-works/pi-coding-agent";
import type {
  AuthorizerLog,
  PermissionsService,
  PromptPermissionDetails,
} from "@gotgenes/pi-permission-system";
import { attach } from "neovim";
import { Type } from "typebox";
import { getVibingModeService } from "../vibing-mode/shared.js";
import {
  formatPreviewFailure,
  isPreviewResult,
  type PreviewResult,
} from "./result.js";
import {
  type PreviewEditInput,
  type PreviewWriteInput,
  registerPreviewAwareMutationTools,
  type UnfoldedRange,
} from "./tools.js";

const PERMISSIONS_SERVICE_KEY = Symbol.for(
  "@gotgenes/pi-permission-system:service",
);
const PROPOSAL_AUTHORIZER = "neovim-diff-preview";
const PROPOSAL_ENTRY = "nvim-pi-pending-proposal";
const STATUS_KEY = "pending-proposal";

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

export type Proposal = {
  toolCallId: string;
  toolName: "edit" | "write";
  cwd: string;
  inputPath: string;
  filePath: string;
  mutationPath: string;
  existed: boolean;
  device?: number;
  inode?: number;
  parentDevice?: number;
  parentInode?: number;
  oldContent: string;
  newContent: string;
  unfoldedRanges: UnfoldedRange[];
};

type CandidateProposal = {
  proposal: Proposal;
  previous: Proposal | undefined;
};

type ActivePreview = {
  toolCallId: string;
};

type NvimOperations = {
  openPreview: (proposal: Proposal) => Promise<PreviewResult>;
  refreshBuffer: (filePath: string) => Promise<void>;
  closePreview: (toolCallId: string) => Promise<void>;
  reloadPreview?: () => Promise<void>;
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

/** Resolve a tool path against Pi's working directory. */
function absolutePath(cwd: string, path: string): string {
  return isAbsolute(path) ? resolve(path) : resolve(cwd, path);
}

function isMissingFile(error: unknown): boolean {
  return Boolean(
    error &&
      typeof error === "object" &&
      "code" in error &&
      error.code === "ENOENT",
  );
}

/** Resolve existing symlinks while retaining a missing path suffix. */
async function canonicalMutationPath(filePath: string): Promise<string> {
  let existing = filePath;
  const suffix: string[] = [];
  while (true) {
    try {
      return resolve(await realpath(existing), ...suffix);
    } catch (error) {
      if (!isMissingFile(error)) throw error;
      const parent = dirname(existing);
      if (parent === existing) throw error;
      suffix.unshift(basename(existing));
      existing = parent;
    }
  }
}

/** Run Pi's real edit implementation while capturing its write in memory. */
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

  const filePath = absolutePath(ctx.cwd, input.path);
  const mutationPath = await canonicalMutationPath(filePath);
  const identity = await stat(mutationPath);
  return {
    toolCallId,
    toolName: "edit",
    cwd: ctx.cwd,
    inputPath: input.path,
    filePath,
    mutationPath,
    existed: true,
    device: identity.dev,
    inode: identity.ino,
    oldContent,
    newContent,
    unfoldedRanges: input.unfolded_ranges,
  };
}

/** Build a full-content write proposal from Pi's validated input. */
async function buildWriteProposal(
  toolCallId: string,
  input: PreviewWriteInput,
  cwd: string,
): Promise<Proposal> {
  const filePath = absolutePath(cwd, input.path);
  let oldContent = "";
  let existed = true;
  try {
    oldContent = await readFile(filePath, "utf8");
  } catch (error) {
    if (!isMissingFile(error)) throw error;
    existed = false;
  }

  let mutationPath: string;
  let identity;
  let parentIdentity;
  if (existed) {
    mutationPath = await canonicalMutationPath(filePath);
    identity = await stat(mutationPath);
  } else {
    let canonicalParent: string;
    try {
      canonicalParent = await realpath(dirname(filePath));
    } catch (error) {
      if (isMissingFile(error)) {
        throw new Error(
          `Cannot propose ${input.path} because its parent directory does not exist yet. Create the directory after resolving the current proposal, then retry.`,
        );
      }
      throw error;
    }
    mutationPath = resolve(canonicalParent, basename(filePath));
    parentIdentity = await stat(canonicalParent);
  }
  return {
    toolCallId,
    toolName: "write",
    cwd,
    inputPath: input.path,
    filePath,
    mutationPath,
    existed,
    device: identity?.dev,
    inode: identity?.ino,
    parentDevice: parentIdentity?.dev,
    parentInode: parentIdentity?.ino,
    oldContent,
    newContent: input.content,
    unfoldedRanges: input.unfolded_ranges,
  };
}

/** Execute Lua through the parent Neovim instance's MessagePack-RPC socket. */
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

/** Reload the Lua preview module after Pi's extension runtime reloads. */
async function reloadPreview(): Promise<void> {
  await callNeovim(
    `
      local name = "config.pi.diff_preview"
      local loaded = package.loaded[name]
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

/** Send one proposal directly as structured MessagePack-RPC arguments. */
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

/** Refresh a loaded Neovim buffer after a file changes. */
async function refreshBuffer(filePath: string): Promise<void> {
  await callNeovim('return require("config.pi.diff_preview").refresh(...)', [
    filePath,
  ]);
}

/** Close a preview without making editor availability part of the decision. */
async function closePreview(toolCallId: string): Promise<void> {
  try {
    await callNeovim('return require("config.pi.diff_preview").close(...)', [
      toolCallId,
    ]);
  } catch {
    // A disappearing Neovim instance must not affect proposal state.
  }
}

/** Apply exactly the reviewed snapshot, failing if the target changed meanwhile. */
async function applyProposal(proposal: Proposal): Promise<void> {
  await withFileMutationQueue(proposal.mutationPath, async () => {
    const currentTarget = await canonicalMutationPath(proposal.filePath);
    if (currentTarget !== proposal.mutationPath) {
      throw new Error(
        `Cannot accept the proposal because ${proposal.inputPath} now resolves to a different file. Ask the model to revise it against the current file.`,
      );
    }

    if (!proposal.existed) {
      let parentHandle;
      let handle;
      try {
        parentHandle = await open(
          dirname(proposal.mutationPath),
          constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW,
        );
        const parentIdentity = await parentHandle.stat();
        if (
          parentIdentity.dev !== proposal.parentDevice ||
          parentIdentity.ino !== proposal.parentInode
        ) {
          throw new Error("parent identity changed");
        }
        handle = await open(
          proposal.mutationPath,
          constants.O_CREAT |
            constants.O_EXCL |
            constants.O_WRONLY |
            constants.O_NOFOLLOW,
          0o666,
        );
        await handle.writeFile(proposal.newContent, "utf8");
        await handle.sync();
      } catch (error) {
        throw new Error(
          `Cannot accept the proposal because ${proposal.inputPath} changed after it was proposed. Ask the model to revise it against the current file.`,
          { cause: error },
        );
      } finally {
        await handle?.close();
        await parentHandle?.close();
      }
      return;
    }

    const handle = await open(
      proposal.mutationPath,
      constants.O_RDWR | constants.O_NOFOLLOW,
    );
    try {
      const identity = await handle.stat();
      const currentContent = await handle.readFile("utf8");
      if (
        identity.dev !== proposal.device ||
        identity.ino !== proposal.inode ||
        currentContent !== proposal.oldContent
      ) {
        throw new Error(
          `Cannot accept the proposal because ${proposal.inputPath} changed after it was proposed. Ask the model to revise it against the current file.`,
        );
      }
      await handle.truncate(0);
      if (proposal.newContent.length > 0) {
        await handle.write(proposal.newContent, 0, "utf8");
      }
      await handle.sync();
    } finally {
      await handle.close();
    }
  });
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

function isProposal(value: unknown): value is Proposal {
  if (!value || typeof value !== "object") return false;
  const proposal = value as Partial<Proposal>;
  return (
    (proposal.toolName === "edit" || proposal.toolName === "write") &&
    typeof proposal.toolCallId === "string" &&
    typeof proposal.cwd === "string" &&
    typeof proposal.inputPath === "string" &&
    typeof proposal.filePath === "string" &&
    typeof proposal.mutationPath === "string" &&
    typeof proposal.existed === "boolean" &&
    (proposal.existed
      ? typeof proposal.device === "number" &&
        typeof proposal.inode === "number"
      : typeof proposal.parentDevice === "number" &&
        typeof proposal.parentInode === "number") &&
    typeof proposal.oldContent === "string" &&
    typeof proposal.newContent === "string" &&
    Array.isArray(proposal.unfoldedRanges)
  );
}

function restorePendingProposal(ctx: ExtensionContext): Proposal | undefined {
  let restored: Proposal | undefined;
  for (const entry of ctx.sessionManager.getBranch()) {
    if (entry.type !== "custom" || entry.customType !== PROPOSAL_ENTRY)
      continue;
    const data = entry.data as
      | { action?: unknown; proposal?: unknown }
      | undefined;
    if (data?.action === "clear") restored = undefined;
    if (data?.action === "set" && isProposal(data.proposal))
      restored = data.proposal;
  }
  return restored;
}

/** Register conversational edit/write proposals around Pi's real tools. */
export function registerNeovimDiffPreview(
  pi: ExtensionAPI,
  nvimOperations: NvimOperations = {
    openPreview,
    refreshBuffer,
    closePreview,
    reloadPreview,
  },
): void {
  let pending: Proposal | undefined;
  let candidate: CandidateProposal | undefined;
  let active: ActivePreview | undefined;
  let stopAfterProposal = false;
  let registeredPermissions: AuthorizerService | undefined;
  let disposeAuthorizer: (() => void) | undefined;

  const setStatus = (ctx: ExtensionContext): void => {
    ctx.ui.setStatus(
      STATUS_KEY,
      pending
        ? `proposal: ${basename(pending.filePath)} · /proposal accept|reject`
        : undefined,
    );
  };

  const persistPending = (): void => {
    if (pending) {
      pi.appendEntry(PROPOSAL_ENTRY, { action: "set", proposal: pending });
    } else {
      pi.appendEntry(PROPOSAL_ENTRY, { action: "clear" });
    }
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

    setStatus(ctx);
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
      setStatus(ctx);
      return {
        content: [
          {
            type: "text",
            text: `Proposal pending for ${pending.inputPath}. The file has not changed. Return control to the user so they can discuss it, revise it, or run /proposal accept or /proposal reject.`,
          },
        ],
        details: {
          proposalPending: true,
          path: pending.inputPath,
          toolName: pending.toolName,
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

      const resolved = pending;
      if (action === "accept" && active?.toolCallId !== resolved.toolCallId) {
        ctx.ui.notify(
          "The proposal cannot be accepted because its Neovim diff is not active. Ask the model to revise it or reject it.",
          "error",
        );
        return;
      }
      if (action === "accept") {
        try {
          await applyProposal(resolved);
        } catch (error) {
          ctx.ui.notify(
            error instanceof Error ? error.message : String(error),
            "error",
          );
          return;
        }
      }

      pending = undefined;
      candidate = undefined;
      active = undefined;
      persistPending();
      setStatus(ctx);
      await nvimOperations.closePreview(resolved.toolCallId);

      if (action === "accept") {
        try {
          await nvimOperations.refreshBuffer(resolved.filePath);
        } catch (error) {
          ctx.ui.notify(
            `The proposal was accepted, but Neovim could not refresh the file: ${error instanceof Error ? error.message : String(error)}`,
            "warning",
          );
        }
        ctx.ui.notify(`Accepted proposal for ${resolved.inputPath}.`, "info");
      } else {
        ctx.ui.notify(`Rejected proposal for ${resolved.inputPath}.`, "info");
      }

      const resolution = action === "accept" ? "accepted" : "rejected";
      pi.sendMessage(
        {
          customType: "nvim-pi-proposal-resolution",
          content:
            action === "accept"
              ? "Proposal accepted."
              : "Proposal rejected.",
          display: true,
          details: {
            action: resolution,
            path: resolved.inputPath,
            toolName: resolved.toolName,
          },
        },
        { triggerTurn: true },
      );
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
      const resolved = pending;
      if (!resolved) {
        return {
          content: [{ type: "text", text: "There is no pending proposal." }],
          details: undefined,
        };
      }
      if (input.action === "accept") {
        // Only apply content that still has its exact reviewed diff visible.
        if (active?.toolCallId !== resolved.toolCallId) {
          throw new Error("The pending proposal has no active Neovim diff.");
        }
        await applyProposal(resolved);
      }

      // Both outcomes finish the review and clear its persisted UI state.
      pending = undefined;
      candidate = undefined;
      active = undefined;
      persistPending();
      setStatus(ctx);
      await nvimOperations.closePreview(resolved.toolCallId);

      // Accepted content is now on disk, so refresh its loaded editor buffer.
      if (input.action === "accept") await nvimOperations.refreshBuffer(resolved.filePath);
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

export default registerNeovimDiffPreview;
