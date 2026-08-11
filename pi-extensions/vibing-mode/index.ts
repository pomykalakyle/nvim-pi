import type {
  AuthorizerLog,
  PermissionsService,
  PromptPermissionDetails,
} from "@gotgenes/pi-permission-system";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import {
  VIBING_MODE_PROMPT_GUIDELINES,
  VIBING_MODE_PROMPT_SNIPPET,
  VIBING_MODE_TOOL_DESCRIPTION,
} from "./policy.js";
import {
  getVibingModeService,
  publishVibingModeService,
  unpublishVibingModeService,
  type VibingModeService,
} from "./shared.js";
import { VibingModeState } from "./state.js";

const PERMISSIONS_SERVICE_KEY = Symbol.for("@gotgenes/pi-permission-system:service");
const STATUS_KEY = "vibing-mode";

type SymbolRegistry = Record<symbol, unknown>;
type AuthorizerService = Pick<PermissionsService, "registerAuthorizer">;

/**
 * Resolve Gotgenes' documented process-global service without a runtime dependency.
 * Reviewed: false.
 */
function getPermissionsService(): AuthorizerService | undefined {
  const candidate = (globalThis as unknown as SymbolRegistry)[PERMISSIONS_SERVICE_KEY];
  if (!candidate || typeof candidate !== "object") return undefined;
  const service = candidate as Partial<AuthorizerService>;
  return typeof service.registerAuthorizer === "function"
    ? (service as AuthorizerService)
    : undefined;
}

/**
 * Build the bounded authorizer callback around request-scoped state.
 * Reviewed: false.
 */
function createAuthorizer(state: VibingModeState) {
  return /** Reviewed: false. */ async (
    details: PromptPermissionDetails,
    _query: unknown,
    log: AuthorizerLog,
  ): Promise<{ kind: "allow" } | { kind: "defer" }> => {
    const requestedPath = details.path
      ?? details.accessIntent?.boundaryValue
      ?? details.accessIntent?.matchValues[0];
    const allowed = state.shouldAuthorize({
      source: details.source,
      toolName: details.toolName,
      path: requestedPath,
      forwarded: details.forwarding !== undefined,
    });
    if (!allowed) return { kind: "defer" };

    log.review("vibing_mode.auto_allow", {
      requestId: details.requestId,
      toolName: details.toolName,
      path: requestedPath,
    });
    return { kind: "allow" };
  };
}

/**
 * Register request-scoped edit approval bypass while preserving every other gate.
 * Reviewed: false.
 */
export default function vibingMode(pi: ExtensionAPI): void {
  const state = new VibingModeState();
  const service: VibingModeService = Object.freeze({
    isActive: /** Reviewed: false. */ () => state.isActive(),
    snapshot: /** Reviewed: false. */ () => state.snapshot(),
    shouldSuppressPreview: /** Reviewed: false. */ (toolName, path) => state.shouldAuthorize({
      source: "tool_call",
      toolName,
      path,
      forwarded: false,
    }),
  });

  let registeredPermissions: AuthorizerService | undefined;
  let disposeAuthorizer: (() => void) | undefined;
  let registrationError: string | undefined;

  /** Ensure registration belongs to the current permission-service generation. */
  const registerAuthorizer = /** Reviewed: false. */ (): boolean => {
    const permissions = getPermissionsService();
    if (!permissions) {
      registrationError = "the permission service is unavailable";
      return false;
    }
    if (registeredPermissions === permissions && disposeAuthorizer) return true;

    try {
      disposeAuthorizer?.();
    } catch {
      // A stale generation's disposer must not prevent a fresh registration.
    }
    registeredPermissions = undefined;
    disposeAuthorizer = undefined;

    try {
      disposeAuthorizer = permissions.registerAuthorizer(
        "vibing-mode",
        createAuthorizer(state),
      );
      registeredPermissions = permissions;
      registrationError = undefined;
      return true;
    } catch (error) {
      registrationError = error instanceof Error ? error.message : String(error);
      // Missing or duplicate registration must fail safe to normal prompting.
      return false;
    }
  };

  const unsubscribePermissionsReady = pi.events.on(
    "permissions:ready",
    registerAuthorizer,
  );

  pi.on("session_start", /** Reviewed: false. */ (_event, ctx) => {
    state.reset();
    ctx.ui.setStatus(STATUS_KEY, undefined);
    publishVibingModeService(service);
    registerAuthorizer();
  });

  pi.on("before_agent_start", /** Reviewed: false. */ (_event, ctx) => {
    state.beginRequest(ctx.cwd);
    ctx.ui.setStatus(STATUS_KEY, undefined);
    registerAuthorizer();
  });

  pi.registerTool({
    name: "vibing_mode",
    label: "Vibing Mode",
    description: VIBING_MODE_TOOL_DESCRIPTION,
    promptSnippet: VIBING_MODE_PROMPT_SNIPPET,
    promptGuidelines: [...VIBING_MODE_PROMPT_GUIDELINES],
    parameters: Type.Object({
      action: Type.String({
        enum: ["enable", "disable", "status"],
        description: "The Vibing Mode state operation.",
      }),
    }),
    /** Reviewed: false. */
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      if (params.action === "enable") {
        if (!registerAuthorizer()) {
          state.disable();
          ctx.ui.setStatus(STATUS_KEY, undefined);
          return {
            content: [{
              type: "text",
              text: `Vibing Mode was not enabled because its permission authorizer could not register: ${registrationError ?? "unknown error"}. Normal edit/write review remains active.`,
            }],
            details: state.snapshot(),
          };
        }

        const result = state.enable();
        if (result.enabled) {
          const snapshot = state.snapshot();
          ctx.ui.setStatus(STATUS_KEY, "⚡ Vibing Mode");
          ctx.ui.notify(
            `Vibing Mode enabled for this request inside ${snapshot.root}.`,
            "warning",
          );
        }
        return {
          content: [{
            type: "text",
            text: result.enabled
              ? `${result.message} Edit/write calls inside the current project may proceed without diff previews or approval. Other tools and external paths keep their normal permissions. The mode ends automatically when this request settles.`
              : `Vibing Mode was not enabled: ${result.message}`,
          }],
          details: state.snapshot(),
        };
      }

      if (params.action === "disable") {
        const wasActive = state.disable();
        ctx.ui.setStatus(STATUS_KEY, undefined);
        if (wasActive) ctx.ui.notify("Vibing Mode disabled; normal edit review restored.", "info");
        return {
          content: [{
            type: "text",
            text: wasActive
              ? "Vibing Mode disabled; normal edit/write preview and approval are restored."
              : "Vibing Mode was already inactive.",
          }],
          details: state.snapshot(),
        };
      }

      if (params.action === "status") {
        const snapshot = state.snapshot();
        return {
          content: [{
            type: "text",
            text: snapshot.active
              ? `Vibing Mode is active for request ${snapshot.requestId} inside ${snapshot.root}.`
              : "Vibing Mode is inactive.",
          }],
          details: snapshot,
        };
      }

      throw new Error(`Unsupported Vibing Mode action: ${String(params.action)}`);
    },
  });

  pi.on("agent_settled", /** Reviewed: false. */ (_event, ctx) => {
    if (!state.settle()) return;
    ctx.ui.setStatus(STATUS_KEY, undefined);
    ctx.ui.notify("Vibing Mode ended; normal edit review is active.", "info");
  });

  pi.on("session_shutdown", /** Reviewed: false. */ (_event, ctx) => {
    state.reset();
    ctx.ui.setStatus(STATUS_KEY, undefined);
    unsubscribePermissionsReady();
    disposeAuthorizer?.();
    disposeAuthorizer = undefined;
    registeredPermissions = undefined;
    unpublishVibingModeService(service);
  });

  // Make the service available to extensions initialized later in the same load.
  if (!getVibingModeService()) publishVibingModeService(service);
}
