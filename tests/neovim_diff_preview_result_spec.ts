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
assert(message.includes("Split the change into smaller edit/write calls and retry."));

console.log("neovim-diff-preview-result-spec-ok");
