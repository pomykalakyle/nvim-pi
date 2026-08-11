// Pi thinking levels in ascending effort order.
export const THINKING_LEVELS = [
  "off",
  "minimal",
  "low",
  "medium",
  "high",
  "xhigh",
  "max",
] as const;

export type ThinkingLevel = (typeof THINKING_LEVELS)[number];
export type ThinkingDirection = "decrease" | "increase";

/**
 * Return the adjacent supported thinking level without wrapping at a boundary.
 * Provenance: vibed=true, reviewed=false.
 */
export function adjacentThinkingLevel(
  current: ThinkingLevel,
  supported: readonly ThinkingLevel[],
  direction: ThinkingDirection,
): ThinkingLevel | undefined {
  const currentIndex = supported.indexOf(current);
  if (currentIndex === -1) return undefined;

  const offset = direction === "increase" ? 1 : -1;
  return supported[currentIndex + offset];
}
