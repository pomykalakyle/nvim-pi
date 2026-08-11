import type {
  ExtensionAPI,
  ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import type { Proposal } from "./proposal.js";

export const PROPOSAL_ENTRY = "nvim-pi-pending-proposal";

/**
 * Persist the current proposal state without adding it to model context.
 * Reviewed: false.
 */
export function persistPendingProposal(
  pi: ExtensionAPI,
  pending: Proposal | undefined,
): void {
  if (pending) {
    pi.appendEntry(PROPOSAL_ENTRY, { action: "set", proposal: pending });
  } else {
    pi.appendEntry(PROPOSAL_ENTRY, { action: "clear" });
  }
}

/** Reviewed: false. */
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
    typeof proposal.justification === "string" &&
    Array.isArray(proposal.unfoldedRanges)
  );
}

/**
 * Add fields absent from proposals persisted by older extension versions.
 * Reviewed: false.
 */
function normalizeProposal(value: unknown): Proposal | undefined {
  let normalized = value;
  if (
    normalized &&
    typeof normalized === "object" &&
    !("justification" in normalized)
  ) {
    normalized = {
      ...normalized,
      justification: "No justification was recorded for this older proposal.",
    };
  }
  return isProposal(normalized) ? normalized : undefined;
}

/**
 * Reconstruct the latest pending proposal on the active session branch.
 * Reviewed: false.
 */
export function restorePendingProposal(
  ctx: ExtensionContext,
): Proposal | undefined {
  let restored: Proposal | undefined;
  for (const entry of ctx.sessionManager.getBranch()) {
    if (entry.type !== "custom" || entry.customType !== PROPOSAL_ENTRY)
      continue;
    const data = entry.data as
      | { action?: unknown; proposal?: unknown }
      | undefined;
    if (data?.action === "clear") restored = undefined;
    if (data?.action === "set") {
      restored = normalizeProposal(data.proposal) ?? restored;
    }
  }
  return restored;
}
