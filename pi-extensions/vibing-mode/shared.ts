import type { VibingModeSnapshot } from "./state.js";

const VIBING_MODE_SERVICE_KEY = Symbol.for("nvim-pi:vibing-mode:service");

type SymbolRegistry = Record<symbol, unknown>;

export type VibingModeService = {
  isActive(): boolean;
  snapshot(): VibingModeSnapshot;
  shouldSuppressPreview(toolName: string, path: string): boolean;
};

/** Return the current Vibing Mode service when a live extension published it. */
export function getVibingModeService(): VibingModeService | undefined {
  const candidate = (globalThis as unknown as SymbolRegistry)[VIBING_MODE_SERVICE_KEY];
  if (!candidate || typeof candidate !== "object") return undefined;

  const service = candidate as Partial<VibingModeService>;
  if (
    typeof service.isActive !== "function"
    || typeof service.snapshot !== "function"
    || typeof service.shouldSuppressPreview !== "function"
  ) {
    return undefined;
  }
  return service as VibingModeService;
}

/** Publish one live extension generation for sibling extension queries. */
export function publishVibingModeService(service: VibingModeService): void {
  (globalThis as unknown as SymbolRegistry)[VIBING_MODE_SERVICE_KEY] = service;
}

/** Remove a service only when this extension generation still owns the slot. */
export function unpublishVibingModeService(service: VibingModeService): void {
  const registry = globalThis as unknown as SymbolRegistry;
  if (registry[VIBING_MODE_SERVICE_KEY] === service) {
    delete registry[VIBING_MODE_SERVICE_KEY];
  }
}
