-- Exercises preview folding against the installed CodeDiff implementation.

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
local codediff_root = vim.env.CODEDIFF_NVIM_ROOT or (vim.fn.stdpath("data") .. "/lazy/codediff.nvim")
assert(vim.fn.isdirectory(codediff_root) == 1, "codediff.nvim is not installed at " .. codediff_root)
vim.opt.runtimepath:prepend(codediff_root)
require("codediff").setup({})
vim.g.pi_diff_preview_layout = "side_by_side"

vim.cmd("silent! only")
local original_buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(original_buf, 0, -1, false, { "editor" })
vim.cmd("rightbelow vsplit")
local terminal_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(0, terminal_buf)
vim.b[terminal_buf].pi_terminal = true

local function preview_windows()
  local windows = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local ok, marked = pcall(vim.api.nvim_win_get_var, win, "pi_diff_preview")
    if ok and marked == true then
      windows[#windows + 1] = win
    end
  end
  return windows
end

local function proposed_window()
  for _, win in ipairs(preview_windows()) do
    local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
    if name:find("/proposed/", 1, true) then
      return win
    end
  end
end

local preview = require("config.pi.diff_preview")

-- CodeDiff chooses the first duplicate as the insertion site. Validation must
-- use that same mapping rather than accepting a different valid alignment.
local repeated_original = table.concat({ "x", "a", "y", "z", "q", "r", "s", "t" }, "\n")
local repeated_proposed = table.concat({ "x", "a", "a", "y", "z", "q", "r", "s", "t" }, "\n")
local mismatched = preview.open({
  tool_call_id = "repeated-hidden",
  file_path = vim.fn.getcwd() .. "/repeated.txt",
  old_content = repeated_original,
  new_content = repeated_proposed,
  unfolded_ranges = { { start_line = 3, end_line = 3 } },
})
assert(mismatched.ok == false)
assert(mismatched.reason == "preview_change_not_visible")

local repeated = preview.open({
  tool_call_id = "repeated-visible",
  file_path = vim.fn.getcwd() .. "/repeated.txt",
  old_content = repeated_original,
  new_content = repeated_proposed,
  unfolded_ranges = { { start_line = 2, end_line = 2 } },
})
assert(repeated.ok == true)
assert(#preview_windows() == 2)
local repeated_proposed_win = assert(proposed_window())
assert(vim.api.nvim_win_call(repeated_proposed_win, function()
  return vim.fn.foldclosed(2)
end) == -1)
local highlights = require("codediff.ui.highlights")
local proposed_buf = vim.api.nvim_win_get_buf(repeated_proposed_win)
assert(#vim.api.nvim_buf_get_extmarks(proposed_buf, highlights.ns_highlight, 0, -1, {}) > 0)

assert(preview.toggle_layout() == nil)
local repeated_unified_win = assert(preview_windows()[1])
assert(vim.api.nvim_win_call(repeated_unified_win, function()
  return vim.fn.foldclosed(2)
end) == -1)
assert(preview.toggle_layout() == nil)
assert(preview.close("repeated-visible"))

-- Both renderers keep their different pure-deletion anchors unfolded.
local small_deletion_original = {}
for line = 1, 100 do
  small_deletion_original[line] = ("line %03d"):format(line)
end
local small_deletion_proposed = vim.list_slice(small_deletion_original, 1, 49)
vim.list_extend(small_deletion_proposed, vim.list_slice(small_deletion_original, 55, 100))
local small_deletion = preview.open({
  tool_call_id = "small-deletion",
  file_path = vim.fn.getcwd() .. "/deletion.txt",
  old_content = table.concat(small_deletion_original, "\n"),
  new_content = table.concat(small_deletion_proposed, "\n"),
  unfolded_ranges = { { start_line = 50, end_line = 50 } },
})
assert(small_deletion.ok == true)
local deletion_proposed_win = assert(proposed_window())
local side_height = vim.api.nvim_win_text_height(deletion_proposed_win, {
  start_row = 0,
  end_row = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(deletion_proposed_win)) - 1,
}).all
assert(side_height >= 8)
assert(vim.api.nvim_win_call(deletion_proposed_win, function()
  return vim.fn.foldclosed(49)
end) == -1)
assert(preview.toggle_layout() == nil)
local deletion_unified_win = assert(preview_windows()[1])
local unified_height = vim.api.nvim_win_text_height(deletion_unified_win, {
  start_row = 0,
  end_row = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(deletion_unified_win)) - 1,
}).all
assert(unified_height >= 8)
assert(preview.close("small-deletion"))

-- Virtual deleted lines count toward unified height and can force rejection.
local deletion_original = {}
for line = 1, 100 do
  deletion_original[line] = ("line %03d"):format(line)
end
local deletion_proposed = vim.list_slice(deletion_original, 1, 49)
vim.list_extend(deletion_proposed, vim.list_slice(deletion_original, 80, 100))
local deletion = preview.open({
  tool_call_id = "large-deletion",
  file_path = vim.fn.getcwd() .. "/deletion.txt",
  old_content = table.concat(deletion_original, "\n"),
  new_content = table.concat(deletion_proposed, "\n"),
  unfolded_ranges = { { start_line = 50, end_line = 50 } },
})
assert(deletion.ok == false)
assert(deletion.reason == "preview_too_tall")
assert(deletion.preview_rows > deletion.viewport_rows)

-- A small selected hunk in a large file remains renderable.
local large_original = {}
local large_proposed = {}
for line = 1, 1000 do
  large_original[line] = ("local value_%04d = %d"):format(line, line)
  large_proposed[line] = large_original[line]
end
large_proposed[500] = "local value_0500 = 'changed'"
local compact = preview.open({
  tool_call_id = "large-file-small-change",
  file_path = vim.fn.getcwd() .. "/large.lua",
  old_content = table.concat(large_original, "\n"),
  new_content = table.concat(large_proposed, "\n"),
  unfolded_ranges = { { start_line = 498, end_line = 502 } },
})
assert(compact.ok == true)
assert(compact.preview_rows < compact.viewport_rows)
assert(preview.close("large-file-small-change"))

print("pi-diff-preview-codediff-spec-ok")
