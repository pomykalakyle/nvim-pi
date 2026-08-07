import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { VIBING_MODE_PROMPT_GUIDELINES } from "../pi-extensions/vibing-mode/policy.ts";
import {
  getVibingModeService,
  publishVibingModeService,
  unpublishVibingModeService,
  type VibingModeService,
} from "../pi-extensions/vibing-mode/shared.ts";
import { VibingModeState } from "../pi-extensions/vibing-mode/state.ts";

const temporaryRoot = mkdtempSync(join(tmpdir(), "pi-vibing-mode-"));
const projectRoot = join(temporaryRoot, "project");
const outsideRoot = join(temporaryRoot, "outside");
mkdirSync(join(projectRoot, "src"), { recursive: true });
mkdirSync(outsideRoot, { recursive: true });
writeFileSync(join(projectRoot, "src", "existing.ts"), "export {};\n");
writeFileSync(join(outsideRoot, "secret.ts"), "export const secret = true;\n");
symlinkSync(outsideRoot, join(projectRoot, "escaped"));

try {
  const promptGuidance = VIBING_MODE_PROMPT_GUIDELINES.join("\n");
  assert.match(promptGuidance, /standing instruction previously given directly by the user/);
  assert.match(promptGuidance, /permission to reactivate Vibing Mode for each matching request/);
  assert.match(promptGuidance, /current user instructions that revoke, narrow, or decline/);
  assert.doesNotMatch(promptGuidance, /standing instructions are not activation/);

  const state = new VibingModeState();
  assert.deepEqual(state.enable(), {
    enabled: false,
    message: "No active user request is available.",
  });

  state.beginRequest(projectRoot);
  assert.equal(state.enable().enabled, true);
  assert.equal(state.isActive(), true);

  assert.equal(state.shouldAuthorize({
    source: "tool_call",
    toolName: "edit",
    path: "src/existing.ts",
    forwarded: false,
  }), true);
  assert.equal(state.shouldAuthorize({
    source: "tool_call",
    toolName: "write",
    path: "src/new/nested.ts",
    forwarded: false,
  }), true);
  assert.equal(state.shouldAuthorize({
    source: "tool_call",
    toolName: "write",
    path: join(outsideRoot, "new.ts"),
    forwarded: false,
  }), false);
  assert.equal(state.shouldAuthorize({
    source: "tool_call",
    toolName: "edit",
    path: "escaped/secret.ts",
    forwarded: false,
  }), false);
  assert.equal(state.shouldAuthorize({
    source: "tool_call",
    toolName: "read",
    path: "src/existing.ts",
    forwarded: false,
  }), false);
  assert.equal(state.shouldAuthorize({
    source: "tool_call",
    toolName: "edit",
    path: "src/existing.ts",
    forwarded: true,
  }), false);
  assert.equal(state.shouldAuthorize({
    source: "skill_input",
    toolName: "edit",
    path: "src/existing.ts",
    forwarded: false,
  }), false);
  assert.equal(state.shouldAuthorize({
    source: "tool_call",
    toolName: "edit",
    forwarded: false,
  }), false);

  assert.equal(state.settle(), true);
  assert.equal(state.isActive(), false);
  assert.equal(state.settle(), false);

  state.beginRequest(projectRoot);
  assert.equal(state.enable().enabled, true);
  state.beginRequest(projectRoot);
  assert.equal(state.isActive(), false);

  const firstService: VibingModeService = {
    isActive: () => true,
    snapshot: () => ({ active: true, requestId: 1, root: projectRoot }),
    shouldSuppressPreview: (toolName, path) => toolName === "write" && path === "inside.ts",
  };
  const secondService: VibingModeService = {
    isActive: () => false,
    snapshot: () => ({ active: false, requestId: null, root: null }),
    shouldSuppressPreview: () => false,
  };
  publishVibingModeService(firstService);
  assert.equal(getVibingModeService(), firstService);
  assert.equal(getVibingModeService()?.shouldSuppressPreview("write", "inside.ts"), true);
  publishVibingModeService(secondService);
  unpublishVibingModeService(firstService);
  assert.equal(getVibingModeService(), secondService);
  unpublishVibingModeService(secondService);
  assert.equal(getVibingModeService(), undefined);
} finally {
  rmSync(temporaryRoot, { recursive: true, force: true });
}

console.log("vibing-mode-spec-ok");
