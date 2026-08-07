import assert from "node:assert/strict";
import {
  formatFocusFailure,
  isFocusResult,
} from "../pi-extensions/neovim-file-focus/result.ts";

assert(isFocusResult({
  ok: true,
  file_path: "/tmp/example.lua",
  start_line: 10,
  end_line: 20,
  viewport_rows: 84,
  range_rows: 11,
  visible_start_line: 1,
  visible_end_line: 84,
}));
assert(isFocusResult({ ok: false, reason: "range_too_tall", message: "Too tall" }));
assert(!isFocusResult({ ok: true }));
assert(!isFocusResult({ ok: false, reason: "range_too_tall" }));
assert(!isFocusResult(undefined));

assert.equal(
  formatFocusFailure({
    ok: false,
    reason: "range_too_tall",
    message: "Requested lines 1-100 require 100 displayed rows, but Neovim has 84",
    restored: true,
    suggested_start_line: 1,
    suggested_end_line: 84,
  }),
  "Requested lines 1-100 require 100 displayed rows, but Neovim has 84 "
    + "The previous editor view was restored. "
    + "Lines 1-84 would fit; choose a smaller range and retry.",
);

console.log("neovim-file-focus-result-spec-ok");
