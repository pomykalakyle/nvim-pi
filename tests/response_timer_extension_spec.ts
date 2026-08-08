import assert from "node:assert/strict";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { registerResponseTimer } from "../pi-extensions/response-timer/index.js";

const handlers = new Map<string, Function>();
const pi = {
  on(event: string, handler: Function) {
    handlers.set(event, handler);
  },
} as unknown as ExtensionAPI;

let now = 10_000;
let tick: (() => void) | undefined;
let clearedTimers = 0;
registerResponseTimer(pi, {
  now: () => now,
  setInterval(callback) {
    tick = callback;
    return 1 as unknown as ReturnType<typeof setInterval>;
  },
  clearInterval() {
    clearedTimers++;
    tick = undefined;
  },
});

const statuses: Array<string | undefined> = [];
const context = {
  ui: {
    theme: {
      fg(_color: string, text: string) {
        return text;
      },
    },
    setStatus(key: string, text: string | undefined) {
      assert.equal(key, "response-timer");
      statuses.push(text);
    },
  },
};

await handlers.get("session_start")?.({}, context);
assert.deepEqual(statuses, [undefined]);

await handlers.get("before_agent_start")?.({}, context);
assert.equal(statuses.at(-1), "response 0ms");
assert(tick);

now += 84_000;
tick();
assert.equal(statuses.at(-1), "response 1m 24s");

now += 3_000;
await handlers.get("agent_settled")?.({}, context);
assert.equal(statuses.at(-1), "response 1m 27s");
assert.equal(clearedTimers, 1);
assert.equal(tick, undefined);

await handlers.get("session_shutdown")?.({}, context);
assert.equal(statuses.at(-1), undefined);
