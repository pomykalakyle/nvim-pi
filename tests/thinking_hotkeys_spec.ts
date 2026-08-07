import assert from "node:assert/strict";
import {
  adjacentThinkingLevel,
  type ThinkingLevel,
} from "../pi-extensions/thinking-hotkeys/levels.ts";

const full: ThinkingLevel[] = [
  "off",
  "minimal",
  "low",
  "medium",
  "high",
  "xhigh",
  "max",
];
assert.equal(adjacentThinkingLevel("medium", full, "decrease"), "low");
assert.equal(adjacentThinkingLevel("medium", full, "increase"), "high");
assert.equal(adjacentThinkingLevel("off", full, "decrease"), undefined);
assert.equal(adjacentThinkingLevel("max", full, "increase"), undefined);

const limited: ThinkingLevel[] = ["off", "low", "medium", "high"];
assert.equal(adjacentThinkingLevel("off", limited, "increase"), "low");
assert.equal(adjacentThinkingLevel("high", limited, "decrease"), "medium");
assert.equal(adjacentThinkingLevel("minimal", limited, "increase"), undefined);

console.log("thinking-hotkeys-spec-ok");
