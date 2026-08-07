import assert from "node:assert/strict";
import { join } from "node:path";
import { createEventBus } from "/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/dist/core/event-bus.js";
import { loadExtensions } from "/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/dist/core/extensions/loader.js";

const PERMISSIONS_SERVICE_KEY = Symbol.for("@gotgenes/pi-permission-system:service");
const VIBING_MODE_SERVICE_KEY = Symbol.for("nvim-pi:vibing-mode:service");
const extensionPath = join(process.cwd(), "pi-extensions/vibing-mode/index.ts");

function createPermissionsService() {
  const authorizers = new Map();
  let registrationAttempts = 0;

  return {
    get registrationAttempts() {
      return registrationAttempts;
    },
    getAuthorizer(name) {
      return authorizers.get(name);
    },
    registerAuthorizer(name, authorizer) {
      registrationAttempts += 1;
      if (authorizers.has(name)) {
        throw new Error(`An authorizer is already registered for '${name}'.`);
      }

      authorizers.set(name, authorizer);
      return () => {
        if (authorizers.get(name) === authorizer) authorizers.delete(name);
      };
    },
  };
}

function createContext() {
  return {
    cwd: process.cwd(),
    ui: {
      notify() {},
      setStatus() {},
    },
  };
}

async function emitExtensionEvent(extension, eventName, event, context) {
  for (const handler of extension.handlers.get(eventName) ?? []) {
    await handler(event, context);
  }
}

const eventBus = createEventBus();
const context = createContext();

try {
  for (let generation = 1; generation <= 3; generation += 1) {
    const loaded = await loadExtensions([extensionPath], process.cwd(), eventBus);
    assert.deepEqual(loaded.errors, []);
    assert.equal(loaded.extensions.length, 1);
    const extension = loaded.extensions[0];

    const permissions = createPermissionsService();
    globalThis[PERMISSIONS_SERVICE_KEY] = permissions;
    eventBus.emit("permissions:ready", undefined);

    assert.equal(
      permissions.registrationAttempts,
      1,
      `reload generation ${generation} should have exactly one permissions listener`,
    );

    await emitExtensionEvent(extension, "before_agent_start", {}, context);
    const vibingModeTool = extension.tools.get("vibing_mode")?.definition;
    assert.ok(vibingModeTool);
    const enableResult = await vibingModeTool.execute(
      `enable-${generation}`,
      { action: "enable" },
      undefined,
      undefined,
      context,
    );
    assert.match(enableResult.content[0].text, /Vibing Mode enabled/);

    const authorizer = permissions.getAuthorizer("vibing-mode");
    assert.ok(authorizer);
    const log = { review() {} };
    assert.deepEqual(
      await authorizer({
        source: "tool_call",
        toolName: "edit",
        path: "pi-extensions/vibing-mode/state.ts",
        requestId: generation,
      }, undefined, log),
      { kind: "allow" },
    );
    assert.deepEqual(
      await authorizer({
        source: "tool_call",
        toolName: "edit",
        path: join(process.cwd(), "..", "outside.ts"),
        requestId: generation,
      }, undefined, log),
      { kind: "defer" },
    );
    assert.deepEqual(
      await authorizer({
        source: "tool_call",
        toolName: "read",
        path: "pi-extensions/vibing-mode/state.ts",
        requestId: generation,
      }, undefined, log),
      { kind: "defer" },
    );

    await emitExtensionEvent(
      extension,
      "session_shutdown",
      { reason: "reload" },
      context,
    );
  }
} finally {
  eventBus.clear();
  delete globalThis[PERMISSIONS_SERVICE_KEY];
  delete globalThis[VIBING_MODE_SERVICE_KEY];
}

console.log("vibing-mode-reload-spec-ok");
