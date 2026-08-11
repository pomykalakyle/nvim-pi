import { existsSync, realpathSync } from "node:fs";
import { basename, dirname, isAbsolute, relative, resolve } from "node:path";

export type VibingModeSnapshot = {
  active: boolean;
  requestId: number | null;
  root: string | null;
};

export type VibingModeAuthorization = {
  source: string;
  toolName?: string;
  path?: string;
  forwarded: boolean;
};

type RequestState = {
  id: number;
  root: string;
};

/**
 * Resolve existing ancestors through symlinks while retaining missing suffixes.
 * Reviewed: false.
 */
function canonicalCandidate(path: string): string {
  const original = resolve(path);
  let cursor = original;
  const missingParts: string[] = [];

  while (!existsSync(cursor)) {
    const parent = dirname(cursor);
    if (parent === cursor) return original;
    missingParts.unshift(basename(cursor));
    cursor = parent;
  }

  try {
    return resolve(realpathSync.native(cursor), ...missingParts);
  } catch {
    return original;
  }
}

/**
 * Return whether candidate stays at or below the canonical request root.
 * Reviewed: false.
 */
function isInsideRoot(root: string, candidate: string): boolean {
  const difference = relative(root, candidate);
  return difference === "" || (!difference.startsWith("..") && !isAbsolute(difference));
}

/** Track one fail-closed Vibing Mode activation for the current user request. */
export class VibingModeState {
  private nextRequestId = 1;
  private request: RequestState | undefined;
  private active = false;

  /**
   * Begin a request and clear every earlier activation.
   * Reviewed: false.
   */
  beginRequest(cwd: string): void {
    this.active = false;
    this.request = {
      id: this.nextRequestId++,
      root: canonicalCandidate(cwd),
    };
  }

  /**
   * Clear request state when a session ends or reloads.
   * Reviewed: false.
   */
  reset(): void {
    this.active = false;
    this.request = undefined;
  }

  /**
   * Enable after the agent establishes direct or applicable standing user authorization.
   * Reviewed: false.
   */
  enable(): { enabled: boolean; message: string } {
    if (!this.request) {
      return { enabled: false, message: "No active user request is available." };
    }
    this.active = true;
    return {
      enabled: true,
      message: `Vibing Mode enabled for request ${this.request.id}.`,
    };
  }

  /**
   * Disable the current activation without discarding request metadata.
   * Reviewed: false.
   */
  disable(): boolean {
    const wasActive = this.active;
    this.active = false;
    return wasActive;
  }

  /**
   * End the request-scoped capability once Pi has fully settled.
   * Reviewed: false.
   */
  settle(): boolean {
    return this.disable();
  }

  /**
   * Return whether edit preview and approval bypass are currently active.
   * Reviewed: false.
   */
  isActive(): boolean {
    return this.active;
  }

  /**
   * Return a non-sensitive state snapshot for tools and sibling extensions.
   * Reviewed: false.
   */
  snapshot(): VibingModeSnapshot {
    return {
      active: this.active,
      requestId: this.request?.id ?? null,
      root: this.request?.root ?? null,
    };
  }

  /**
   * Allow only top-level edit/write asks confined to the activation root.
   * Reviewed: false.
   */
  shouldAuthorize(request: VibingModeAuthorization): boolean {
    if (!this.active || !this.request) return false;
    if (request.forwarded || request.source !== "tool_call") return false;
    if (request.toolName !== "edit" && request.toolName !== "write") return false;
    if (!request.path) return false;

    const absolute = isAbsolute(request.path)
      ? resolve(request.path)
      : resolve(this.request.root, request.path);
    return isInsideRoot(this.request.root, canonicalCandidate(absolute));
  }
}
