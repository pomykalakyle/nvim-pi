import { getSupportedThinkingLevels } from "@earendil-works/pi-ai";
import type {
  ExtensionAPI,
  ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import {
  adjacentThinkingLevel,
  type ThinkingDirection,
  type ThinkingLevel,
} from "./levels.js";

/** Move one step through the active model's supported thinking levels. */
function changeThinkingLevel(
  pi: ExtensionAPI,
  ctx: ExtensionContext,
  direction: ThinkingDirection,
): void {
  if (!ctx.model) return;

  const current = pi.getThinkingLevel() as ThinkingLevel;
  const supported = getSupportedThinkingLevels(ctx.model) as ThinkingLevel[];
  const target = adjacentThinkingLevel(current, supported, direction);
  if (target) pi.setThinkingLevel(target);
}

/** Register directional thinking-level shortcuts. */
export default function thinkingHotkeys(pi: ExtensionAPI): void {
  pi.registerShortcut("alt+,", {
    description: "Decrease thinking level",
    handler: (ctx) => changeThinkingLevel(pi, ctx, "decrease"),
  });

  pi.registerShortcut("alt+.", {
    description: "Increase thinking level",
    handler: (ctx) => changeThinkingLevel(pi, ctx, "increase"),
  });
}
