import assert from "node:assert/strict";
import {
  formatPreviewFailure,
  isPreviewResult,
} from "../pi-extensions/neovim-diff-preview/result.js";

assert(isPreviewResult({
  ok: true,
  file_path: "/tmp/example.lua",
  preview_rows: 20,
  viewport_rows: 84,
}));
assert(isPreviewResult({
  ok: false,
  reason: "preview_too_tall",
  message: "The proposed example.lua diff requires 120 displayed rows, but Neovim has 84",
  preview_rows: 120,
  viewport_rows: 84,
}));
assert(!isPreviewResult(true));
assert(!isPreviewResult({ ok: false, reason: "preview_too_tall" }));

const message = formatPreviewFailure({
  ok: false,
  reason: "preview_too_tall",
  message: "The proposed example.lua diff requires 120 displayed rows, but Neovim has 84",
  preview_rows: 120,
  viewport_rows: 84,
});
assert(message.includes("current 84-row Neovim viewport"));
assert(message.includes("Tighten unfolded_ranges or split the change"));

const uncoveredMessage = formatPreviewFailure({
  ok: false,
  reason: "preview_change_not_visible",
  message: "unfolded_ranges do not fully contain changed proposed lines 20-24",
});
assert(uncoveredMessage.includes("Expand unfolded_ranges"));
assert(uncoveredMessage.includes("every changed hunk"));

const invalidRangeMessage = formatPreviewFailure({
  ok: false,
  reason: "preview_range_out_of_bounds",
  message: "unfolded_ranges[1] ends at proposed line 50, but the proposed file has 40 lines",
});
assert(invalidRangeMessage.includes("1-based inclusive lines from the proposed file"));

const invalidRequestMessage = formatPreviewFailure({
  ok: false,
  reason: "preview_invalid_request",
  message: "Pi diff preview requires valid nonempty unfolded_ranges",
});
assert(invalidRequestMessage.includes("Provide valid nonempty unfolded_ranges"));

const renderFailureMessage = formatPreviewFailure({
  ok: false,
  reason: "preview_render_failed",
  message: "CodeDiff failed to render the preview",
});
assert(renderFailureMessage.includes("edit/write call was not executed"));

const workspaceFailureMessage = formatPreviewFailure({
  ok: false,
  reason: "workspace_unavailable",
  message: "The requesting Pi workspace is unavailable",
});
assert(workspaceFailureMessage.includes("originating Pi workspace"));

console.log("neovim-diff-preview-result-spec-ok");
