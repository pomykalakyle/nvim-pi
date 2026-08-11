import type {
  ExtensionAPI,
  ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import prettyMilliseconds from "pretty-ms";

const STATUS_KEY = "response-timer";
const UPDATE_INTERVAL_MS = 1000;
const FORMAT_OPTIONS = {
  secondsDecimalDigits: 0,
  unitCount: 2,
} as const;

type TimerHandle = ReturnType<typeof setInterval>;
type TimerDependencies = {
  now(): number;
  setInterval(callback: () => void, milliseconds: number): TimerHandle;
  clearInterval(handle: TimerHandle): void;
};

const defaultDependencies: TimerDependencies = {
  now: Date.now,
  setInterval,
  clearInterval,
};

/**
 * Registers a footer status that measures each complete agent response.
 * Reviewed: false.
 */
export function registerResponseTimer(
  pi: ExtensionAPI,
  dependencies: TimerDependencies = defaultDependencies,
): void {
  let startedAt: number | undefined;
  let timer: TimerHandle | undefined;

  /** Stops the render loop without clearing the last displayed duration. */
  const clearTimer = /** Reviewed: false. */ (): void => {
    if (timer === undefined) return;
    dependencies.clearInterval(timer);
    timer = undefined;
  };

  /** Re-renders the current elapsed duration through Pi's built-in footer. */
  const updateStatus = /** Reviewed: false. */ (ctx: ExtensionContext): void => {
    if (startedAt === undefined) return;
    const elapsed = prettyMilliseconds(dependencies.now() - startedAt, FORMAT_OPTIONS);
    ctx.ui.setStatus(STATUS_KEY, ctx.ui.theme.fg("dim", `response ${elapsed}`));
  };

  pi.on("session_start", /** Reviewed: false. */ (_event, ctx) => {
    clearTimer();
    startedAt = undefined;
    ctx.ui.setStatus(STATUS_KEY, undefined);
  });

  // This event runs once Pi has accepted and prepared the submitted prompt.
  pi.on("before_agent_start", /** Reviewed: false. */ (_event, ctx) => {
    clearTimer();
    startedAt = dependencies.now();
    updateStatus(ctx);
    timer = dependencies.setInterval(/** Reviewed: false. */ () => updateStatus(ctx), UPDATE_INTERVAL_MS);
  });

  // Settled includes retries, compaction retries, and queued follow-up work.
  pi.on("agent_settled", /** Reviewed: false. */ (_event, ctx) => {
    if (startedAt === undefined) return;
    clearTimer();
    updateStatus(ctx);
  });

  pi.on("session_shutdown", /** Reviewed: false. */ (_event, ctx) => {
    clearTimer();
    startedAt = undefined;
    ctx.ui.setStatus(STATUS_KEY, undefined);
  });
}

export default registerResponseTimer;
