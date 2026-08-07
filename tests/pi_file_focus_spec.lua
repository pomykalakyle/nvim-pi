-- Verifies agent-selected file ranges displayed beside the requesting Pi terminal.

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

vim.o.lines = 48
vim.o.columns = 180
vim.o.hidden = true
vim.cmd("silent! only")

local original_win = vim.api.nvim_get_current_win()
local original_buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(original_buf, 0, -1, false, { "original editor contents" })
vim.api.nvim_win_set_cursor(original_win, { 1, 0 })
local original_view = vim.api.nvim_win_call(original_win, vim.fn.winsaveview)

-- Put the requesting Pi terminal to the left of the normal editor window.
vim.cmd("leftabove vsplit")
local terminal_win = vim.api.nvim_get_current_win()
local terminal_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(terminal_win, terminal_buf)
vim.b[terminal_buf].pi_terminal = true
vim.b[terminal_buf].terminal_job_pid = 4242

local temporary_directory = vim.fn.tempname()
vim.fn.mkdir(temporary_directory, "p")
local file_path = temporary_directory .. "/example.lua"
local file_lines = {}
for line = 1, 160 do
  file_lines[line] = ("local value_%03d = %d"):format(line, line)
end
vim.fn.writefile(file_lines, file_path)

local focus = require("config.pi.file_focus")
local viewport_rows = vim.api.nvim_win_get_height(original_win)
assert(viewport_rows > 20)

local shown = focus.focus({
  requester_pid = 4242,
  file_path = file_path,
  start_line = 40,
  end_line = 55,
})
assert(shown.ok == true)
assert(shown.start_line == 40)
assert(shown.end_line == 55)
assert(shown.viewport_rows == viewport_rows)
assert(shown.range_rows == 16)
assert(shown.visible_start_line <= 40)
assert(shown.visible_end_line >= 55)
assert(vim.api.nvim_get_current_win() == terminal_win)
assert(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(original_win)) == vim.uv.fs_realpath(file_path))
assert(vim.api.nvim_win_get_var(original_win, "pi_file_focus_target") == true)

local shown_buf = vim.api.nvim_win_get_buf(original_win)
local focus_namespace = assert(vim.api.nvim_get_namespaces().pi_file_focus_4242)
local dim_marks = vim.api.nvim_buf_get_extmarks(shown_buf, focus_namespace, 0, -1, { details = true })
assert(#dim_marks == 2)
assert(dim_marks[1][2] == 0)
assert(dim_marks[1][4].end_row == 38)
assert(dim_marks[2][2] == 55)
assert(dim_marks[2][4].end_row == 159)

-- Editor interaction preserves focus, and toggling hides and restores only the dimming.
vim.api.nvim_set_current_win(original_win)
vim.api.nvim_win_set_cursor(original_win, { 42, 0 })
assert(#vim.api.nvim_buf_get_extmarks(shown_buf, focus_namespace, 0, -1, {}) == 2)
local hidden = focus.toggle_current_tab()
assert(hidden.count == 1)
assert(hidden.enabled == false)
assert(#vim.api.nvim_buf_get_extmarks(shown_buf, focus_namespace, 0, -1, {}) == 0)
assert(vim.api.nvim_win_get_cursor(original_win)[1] == 42)
local restored = focus.toggle_current_tab()
assert(restored.count == 1)
assert(restored.enabled == true)
assert(#vim.api.nvim_buf_get_extmarks(shown_buf, focus_namespace, 0, -1, {}) == 2)
assert(vim.api.nvim_win_get_cursor(original_win)[1] == 42)

-- The explicit clear command still forgets the focus completely.
assert(vim.fn.exists(":PiFocusClear") == 2)
vim.cmd("PiFocusClear")
assert(#vim.api.nvim_buf_get_extmarks(shown_buf, focus_namespace, 0, -1, {}) == 0)
assert(focus.clear_current_tab() == 0)
local empty_toggle = focus.toggle_current_tab()
assert(empty_toggle.count == 0)
assert(empty_toggle.enabled == false)
vim.api.nvim_set_current_win(terminal_win)

-- A later focus call reapplies styling normally.
-- Closed folds cannot make hidden source lines appear to fit.
vim.api.nvim_win_call(original_win, function()
  vim.wo.foldmethod = "manual"
  vim.cmd("40,55fold")
  vim.cmd("40foldclose")
  assert(vim.fn.foldclosed(40) == 40)
end)
local unfolded = focus.focus({
  requester_pid = 4242,
  file_path = file_path,
  start_line = 40,
  end_line = 55,
})
assert(unfolded.ok == true)
assert(unfolded.range_rows == 16)
assert(vim.api.nvim_win_call(original_win, function()
  return vim.fn.foldclosed(40)
end) == -1)

-- A loaded modified buffer wins over the on-disk copy.
vim.api.nvim_buf_set_lines(shown_buf, 39, 40, false, { "local unsaved_value = true" })
local reused = focus.focus({
  requester_pid = 4242,
  file_path = file_path,
  start_line = 40,
  end_line = 40,
})
assert(reused.ok == true)
assert(vim.api.nvim_win_get_buf(original_win) == shown_buf)
assert(vim.api.nvim_buf_get_lines(shown_buf, 39, 40, false)[1] == "local unsaved_value = true")
assert(focus.clear(4242))
assert(#vim.api.nvim_buf_get_extmarks(shown_buf, focus_namespace, 0, -1, {}) == 0)
assert(not focus.clear(4242))

-- An oversized range is rejected, reports a fitting suggestion, and restores the view.
vim.api.nvim_win_set_buf(original_win, original_buf)
vim.api.nvim_win_call(original_win, function()
  vim.fn.winrestview(original_view)
end)
local rejected = focus.focus({
  requester_pid = 4242,
  file_path = file_path,
  start_line = 1,
  end_line = 160,
})
assert(rejected.ok == false)
assert(rejected.reason == "range_too_tall")
assert(rejected.viewport_rows == viewport_rows)
assert(rejected.range_rows == 160)
assert(rejected.suggested_start_line == 1)
assert(rejected.suggested_end_line >= 1)
assert(rejected.suggested_end_line <= viewport_rows)
assert(rejected.restored == true)
assert(vim.api.nvim_win_get_buf(original_win) == original_buf)
assert(vim.deep_equal(vim.api.nvim_win_call(original_win, vim.fn.winsaveview), original_view))
assert(vim.api.nvim_get_current_win() == terminal_win)

local wrong_terminal = focus.focus({
  requester_pid = 9999,
  file_path = file_path,
  start_line = 1,
  end_line = 2,
})
assert(wrong_terminal.ok == false)
assert(wrong_terminal.reason == "requesting_terminal_not_visible")

local invalid_range = focus.focus({
  requester_pid = 4242,
  file_path = file_path,
  start_line = 100,
  end_line = 200,
})
assert(invalid_range.ok == false)
assert(invalid_range.reason == "range_out_of_bounds")
assert(vim.api.nvim_win_get_buf(original_win) == original_buf)

vim.b[terminal_buf].pi_terminal = false
vim.b[terminal_buf].terminal_job_pid = nil
vim.api.nvim_buf_delete(shown_buf, { force = true })
vim.fn.delete(temporary_directory, "rf")

print("pi-file-focus-spec-ok")
