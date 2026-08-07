import assert from "node:assert/strict";
import backExtension from "../pi-extensions/back/index.ts";
import { findLatestUserMessageId } from "../pi-extensions/back/find-latest-user-message.ts";

const branch = [
  { id: "user-1", type: "message", message: { role: "user" } },
  { id: "assistant-1", type: "message", message: { role: "assistant" } },
  { id: "tool-1", type: "message", message: { role: "toolResult" } },
  { id: "user-2", type: "message", message: { role: "user" } },
  { id: "assistant-2", type: "message", message: { role: "assistant" } },
];

assert.equal(findLatestUserMessageId(branch), "user-2");
assert.equal(
  findLatestUserMessageId([
    { id: "assistant", type: "message", message: { role: "assistant" } },
    { id: "label", type: "label" },
  ]),
  undefined,
);
assert.equal(findLatestUserMessageId([]), undefined);

let commandName: string | undefined;
let commandHandler: ((args: string, ctx: any) => Promise<void>) | undefined;
backExtension({
  registerCommand(name: string, options: { handler: typeof commandHandler }) {
    commandName = name;
    commandHandler = options.handler;
  },
} as any);

assert.equal(commandName, "back");
assert.ok(commandHandler);

const events: string[] = [];
await commandHandler("", {
  isIdle: () => false,
  abort: () => events.push("abort"),
  waitForIdle: async () => {
    events.push("wait");
  },
  sessionManager: {
    getBranch: () => {
      events.push("branch");
      return branch;
    },
  },
  navigateTree: async (entryId: string, options: { summarize: boolean }) => {
    events.push(`navigate:${entryId}:${String(options.summarize)}`);
  },
  ui: { notify: () => undefined },
});

assert.deepEqual(events, ["abort", "wait", "branch", "navigate:user-2:false"]);

console.log("back-spec-ok");
