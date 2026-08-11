export interface BranchEntryLike {
  id: string;
  type: string;
  message?: {
    role: string;
  };
}

/**
 * Find the most recent user-message entry on an active session branch.
 * Reviewed: false.
 */
export function findLatestUserMessageId(
  entries: readonly BranchEntryLike[],
): string | undefined {
  for (let index = entries.length - 1; index >= 0; index -= 1) {
    const entry = entries[index];
    if (entry.type === "message" && entry.message?.role === "user") {
      return entry.id;
    }
  }

  return undefined;
}
