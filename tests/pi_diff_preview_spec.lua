-- Verifies the read-only Neovim display used for Pi edit proposals.

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
vim.g.pi_diff_preview_layout = "side_by_side"

local inline_compute_count = 0
local inline_render_count = 0
local inline_clear_count = 0
local inline_render_error
local diff_hit_timeout = false

package.loaded["lazy"] = {
  load = function(options)
    assert(vim.deep_equal(options.plugins, { "codediff.nvim" }))
  end,
}

package.loaded["codediff.core.diff"] = {
  compute_diff = function(original_lines, proposed_lines, options)
    inline_compute_count = inline_compute_count + 1
    assert(options.max_computation_time_ms == 5000)
    local changes = {}
    local hunks = vim.diff(table.concat(original_lines, "\n"), table.concat(proposed_lines, "\n"), {
      result_type = "indices",
    })
    for _, hunk in ipairs(hunks) do
      local original_start, original_count, proposed_start, proposed_count = unpack(hunk)
      local original_boundary = original_count == 0 and original_start + 1 or original_start
      local proposed_boundary = proposed_count == 0 and proposed_start + 1 or proposed_start
      changes[#changes + 1] = {
        original = { start_line = original_boundary, end_line = original_boundary + original_count },
        modified = { start_line = proposed_boundary, end_line = proposed_boundary + proposed_count },
        inner_changes = {},
      }
    end
    return { changes = changes, moves = {}, hit_timeout = diff_hit_timeout }
  end,
}

package.loaded["codediff.ui.core"] = {
  render_diff = function(original_buf, proposed_buf, original_lines, proposed_lines, result)
    assert(vim.api.nvim_buf_is_valid(original_buf))
    assert(vim.api.nvim_buf_is_valid(proposed_buf))
    assert(type(original_lines[1]) == "string")
    assert(type(proposed_lines[1]) == "string")
    assert(type(result.changes) == "table")
  end,
}

package.loaded["codediff.ui.lifecycle"] = {
  clear_highlights = function(buf)
    assert(vim.api.nvim_buf_is_valid(buf))
  end,
}

package.loaded["codediff.ui.scroll"] = {
  bind = function(_, windows)
    assert(#windows == 2)
  end,
  resync = function() end,
  teardown = function() end,
}

package.loaded["codediff.ui.inline"] = {
  render_inline_diff = function(buf, result, original_lines, proposed_lines, options)
    inline_render_count = inline_render_count + 1
    if inline_render_error then
      error(inline_render_error)
    end
    assert(vim.api.nvim_buf_is_valid(buf))
    assert(type(result.changes) == "table")
    assert(type(original_lines[1]) == "string")
    assert(type(proposed_lines[1]) == "string")
    assert(options.filetype == "lua")
  end,
  clear = function(buf)
    inline_clear_count = inline_clear_count + 1
    assert(vim.api.nvim_buf_is_valid(buf))
  end,
}

vim.cmd("silent! only")
local original_win = vim.api.nvim_get_current_win()
local original_buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(original_buf, 0, -1, false, { "original editor buffer" })
vim.wo[original_win].foldenable = false
vim.wo[original_win].foldmethod = "indent"
vim.wo[original_win].foldcolumn = "3"
local original_fold_options = {
  foldenable = vim.wo[original_win].foldenable,
  foldmethod = vim.wo[original_win].foldmethod,
  foldcolumn = vim.wo[original_win].foldcolumn,
  diff = vim.wo[original_win].diff,
}

vim.cmd("rightbelow vsplit")
local pi_terminal_win = vim.api.nvim_get_current_win()
local pi_terminal_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(pi_terminal_win, pi_terminal_buf)
vim.b[pi_terminal_buf].pi_terminal = true

local payload = {
  tool_call_id = "preview-test",
  file_path = vim.fn.getcwd() .. "/example.lua",
  old_content = 'local value = "before"\nreturn value\n',
  new_content = 'local value = "after"\nreturn value\n',
  unfolded_ranges = { { start_line = 1, end_line = 2 } },
}

---Return all windows managed by the Pi diff preview.
---The production window marker avoids depending on split positions.
local function preview_windows()
  local windows = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local ok, value = pcall(vim.api.nvim_win_get_var, win, "pi_diff_preview")
    if ok and value == true then
      windows[#windows + 1] = win
    end
  end
  return windows
end

---Find a preview window by its synthetic buffer-name component.
---Synthetic names distinguish the original and proposed sides.
local function find_preview_window(component)
  for _, win in ipairs(preview_windows()) do
    local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
    if name:find(component, 1, true) then
      return win
    end
  end
end

local preview = require("config.pi.diff_preview")
local invalid_notification
local original_notify = vim.notify
vim.notify = function(message, level)
  invalid_notification = { message = message, level = level }
end
local missing_ranges = preview.open({
  tool_call_id = payload.tool_call_id,
  file_path = payload.file_path,
  old_content = payload.old_content,
  new_content = payload.new_content,
})
vim.notify = original_notify
assert(missing_ranges.ok == false)
assert(missing_ranges.reason == "preview_invalid_request")
assert(invalid_notification.message:find("requires valid nonempty unfolded_ranges", 1, true))
assert(invalid_notification.level == vim.log.levels.ERROR)

vim.notify = function() end
local descending_ranges = preview.open({
  tool_call_id = payload.tool_call_id,
  file_path = payload.file_path,
  old_content = payload.old_content,
  new_content = payload.new_content,
  unfolded_ranges = { { start_line = 2, end_line = 1 } },
})
vim.notify = original_notify
assert(descending_ranges.ok == false)
assert(descending_ranges.reason == "preview_invalid_request")

assert(preview.open(payload))

local windows = preview_windows()
assert(#windows == 2)
local preview_before_win = assert(find_preview_window("/original/"))
local preview_proposed_win = assert(find_preview_window("/proposed/"))
local preview_before_buf = vim.api.nvim_win_get_buf(preview_before_win)
local preview_proposed_buf = vim.api.nvim_win_get_buf(preview_proposed_win)
assert(vim.wo[preview_before_win].diff == false)
assert(vim.wo[preview_proposed_win].diff == false)
assert(vim.wo[preview_before_win].winbar == " Pi proposal: example.lua — Original ")
assert(vim.wo[preview_proposed_win].winbar == " Pi proposal: example.lua — Proposed ")
assert(vim.bo[preview_before_buf].readonly == true)
assert(vim.bo[preview_proposed_buf].readonly == true)
assert(vim.bo[preview_before_buf].modifiable == false)
assert(vim.bo[preview_proposed_buf].modifiable == false)
assert(vim.bo[preview_before_buf].filetype == "lua")
assert(vim.api.nvim_buf_get_lines(preview_before_buf, 0, 1, false)[1] == 'local value = "before"')
assert(vim.api.nvim_buf_get_lines(preview_proposed_buf, 0, 1, false)[1] == 'local value = "after"')
assert(vim.api.nvim_win_get_position(preview_proposed_win)[2] > vim.api.nvim_win_get_position(preview_before_win)[2])

-- Both proposal buffers expose the old normal-mode `t` layout toggle.
vim.api.nvim_set_current_win(preview_before_win)
local toggle_mapping = vim.fn.maparg("t", "n", false, true)
assert(toggle_mapping.buffer == 1)
assert(toggle_mapping.desc == "Pi: Toggle diff layout")

inline_render_error = "forced inline render failure"
local toggled, toggle_error = pcall(preview.toggle_layout)
assert(toggled == false)
assert(tostring(toggle_error):find(inline_render_error, 1, true))
assert(#preview_windows() == 2)
assert(vim.g.pi_diff_preview_layout == "side_by_side")
inline_render_error = nil

assert(preview.toggle_layout() == nil)
assert(#preview_windows() == 1)
local unified_win = preview_windows()[1]
assert(vim.api.nvim_win_get_buf(unified_win) == preview_proposed_buf)
assert(vim.wo[unified_win].diff == false)
assert(vim.wo[unified_win].winbar == " Pi proposal: example.lua — Unified ")
assert(inline_compute_count == 1)
assert(inline_render_count == 2)
assert(vim.g.pi_diff_preview_layout == "unified")

vim.api.nvim_feedkeys("t", "x", false)
assert(#preview_windows() == 2)
preview_before_win = assert(find_preview_window("/original/"))
preview_proposed_win = assert(find_preview_window("/proposed/"))
assert(vim.wo[preview_before_win].diff == false)
assert(vim.wo[preview_proposed_win].diff == false)
assert(inline_clear_count == 1)
assert(vim.g.pi_diff_preview_layout == "side_by_side")

assert(preview.close("different-tool-call") == false)
assert(#preview_windows() == 2)

-- Closing unified previews clears decorations and deletes both hidden scratch buffers.
vim.cmd("PiDiffToggle")
assert(#preview_windows() == 1)
assert(inline_compute_count == 1)
assert(inline_render_count == 3)
assert(preview.close("preview-test"))
assert(#preview_windows() == 0)
assert(inline_clear_count == 2)
assert(not vim.api.nvim_buf_is_valid(preview_before_buf))
assert(not vim.api.nvim_buf_is_valid(preview_proposed_buf))
assert(vim.api.nvim_win_is_valid(original_win))
assert(vim.api.nvim_win_get_buf(original_win) == original_buf)
assert(vim.api.nvim_buf_get_lines(original_buf, 0, 1, false)[1] == "original editor buffer")
assert(vim.wo[original_win].foldenable == original_fold_options.foldenable)
assert(vim.wo[original_win].foldmethod == original_fold_options.foldmethod)
assert(vim.wo[original_win].foldcolumn == original_fold_options.foldcolumn)
assert(vim.wo[original_win].diff == original_fold_options.diff)
assert(vim.api.nvim_get_current_win() == pi_terminal_win)

-- The chosen unified layout carries into the next proposal in this session.
assert(preview.open(payload))
assert(#preview_windows() == 1)
assert(inline_compute_count == 2)
assert(inline_render_count == 4)
vim.cmd("PiDiffToggle")
assert(#preview_windows() == 2)
assert(vim.g.pi_diff_preview_layout == "side_by_side")
assert(preview.close("preview-test"))

diff_hit_timeout = true
local timed_out = preview.open(payload)
diff_hit_timeout = false
assert(timed_out.ok == false)
assert(timed_out.reason == "preview_render_failed")
assert(timed_out.message:find("timed out", 1, true))
assert(#preview_windows() == 0)

-- Distant changes can expose multiple review sections while folding everything else.
local viewport_rows = vim.api.nvim_win_get_height(original_win)
local long_original = {}
local long_proposed = {}
for line = 1, viewport_rows * 4 do
  long_original[line] = ("local value_%03d = %d"):format(line, line)
  long_proposed[line] = long_original[line]
end
long_proposed[3] = "local value_003 = 'changed near the top'"
long_proposed[#long_proposed - 2] = "local value_last = 'changed near the bottom'"
local compact = preview.open({
  tool_call_id = "compact-preview",
  file_path = vim.fn.getcwd() .. "/compact.lua",
  old_content = table.concat(long_original, "\n"),
  new_content = table.concat(long_proposed, "\n"),
  unfolded_ranges = {
    { start_line = 2, end_line = 4 },
    { start_line = math.floor(#long_proposed / 2) - 1, end_line = math.floor(#long_proposed / 2) + 1 },
    { start_line = #long_proposed - 3, end_line = #long_proposed - 1 },
  },
})
assert(compact.ok == true)
assert(compact.preview_rows < compact.viewport_rows)
preview_before_win = assert(find_preview_window("/original/"))
preview_proposed_win = assert(find_preview_window("/proposed/"))
assert(vim.api.nvim_win_call(preview_proposed_win, function()
  return vim.fn.foldclosed(3)
end) == -1)
assert(vim.api.nvim_win_call(preview_proposed_win, function()
  return vim.fn.foldclosed(math.floor(#long_proposed / 2))
end) == -1)
local omitted_line = math.floor(#long_proposed / 4)
assert(vim.api.nvim_win_call(preview_proposed_win, function()
  return vim.fn.foldclosed(omitted_line)
end) > 0)
assert(vim.api.nvim_win_call(preview_before_win, function()
  return vim.fn.foldclosed(3)
end) == -1)
assert(vim.api.nvim_win_call(preview_before_win, function()
  return vim.fn.foldclosed(omitted_line)
end) > 0)

-- The same requested sections determine the unified layout's initial folds.
assert(preview.toggle_layout() == nil)
local compact_unified_win = preview_windows()[1]
assert(vim.api.nvim_win_call(compact_unified_win, function()
  return vim.fn.foldclosed(omitted_line)
end) > 0)
assert(preview.toggle_layout() == nil)
preview_proposed_win = assert(find_preview_window("/proposed/"))

-- Folds remain ordinary Neovim folds that the reviewer can open.
vim.api.nvim_win_call(preview_proposed_win, function()
  vim.api.nvim_win_set_cursor(0, { omitted_line, 0 })
  vim.cmd("normal! zo")
  assert(vim.fn.foldclosed(omitted_line) == -1)
end)

-- Leave unified selected and verify a new proposal is measured in that layout.
assert(preview.toggle_layout() == nil)
assert(preview.close("compact-preview"))
local compact_unified = preview.open({
  tool_call_id = "compact-preview-unified",
  file_path = vim.fn.getcwd() .. "/compact.lua",
  old_content = table.concat(long_original, "\n"),
  new_content = table.concat(long_proposed, "\n"),
  unfolded_ranges = {
    { start_line = 2, end_line = 4 },
    { start_line = math.floor(#long_proposed / 2) - 1, end_line = math.floor(#long_proposed / 2) + 1 },
    { start_line = #long_proposed - 3, end_line = #long_proposed - 1 },
  },
})
assert(compact_unified.ok == true)
assert(compact_unified.preview_rows < compact_unified.viewport_rows)
assert(#preview_windows() == 1)
assert(preview.close("compact-preview-unified"))

-- A model cannot omit or partially expose a changed hunk.
local uncovered = preview.open({
  tool_call_id = "uncovered-preview",
  file_path = vim.fn.getcwd() .. "/compact.lua",
  old_content = table.concat(long_original, "\n"),
  new_content = table.concat(long_proposed, "\n"),
  unfolded_ranges = { { start_line = 2, end_line = 4 } },
})
assert(uncovered.ok == false)
assert(uncovered.reason == "preview_change_not_visible")
assert(uncovered.message:find("do not fully contain", 1, true))
assert(#preview_windows() == 0)

local out_of_bounds = preview.open({
  tool_call_id = "out-of-bounds-preview",
  file_path = vim.fn.getcwd() .. "/compact.lua",
  old_content = table.concat(long_original, "\n"),
  new_content = table.concat(long_proposed, "\n"),
  unfolded_ranges = { { start_line = 1, end_line = #long_proposed + 1 } },
})
assert(out_of_bounds.ok == false)
assert(out_of_bounds.reason == "preview_range_out_of_bounds")
assert(#preview_windows() == 0)

local hunk_original = {}
local hunk_proposed = {}
for line = 1, 12 do
  hunk_original[line] = ("local hunk_%02d = 'old'"):format(line)
  hunk_proposed[line] = hunk_original[line]
end
for line = 5, 7 do
  hunk_proposed[line] = ("local hunk_%02d = 'new'"):format(line)
end
local partial_hunk = preview.open({
  tool_call_id = "partial-hunk-preview",
  file_path = vim.fn.getcwd() .. "/partial.lua",
  old_content = table.concat(hunk_original, "\n"),
  new_content = table.concat(hunk_proposed, "\n"),
  unfolded_ranges = { { start_line = 5, end_line = 6 } },
})
assert(partial_hunk.ok == false)
assert(partial_hunk.reason == "preview_change_not_visible")
assert(partial_hunk.message:find("changed proposed lines 5%-7"))
assert(#preview_windows() == 0)

-- Pure deletions are covered by unfolding the following proposed line.
local deletion_original = {}
for line = 1, 12 do
  deletion_original[line] = ("local deletion_%02d = true"):format(line)
end
local deletion_proposed = vim.list_slice(deletion_original, 1, 4)
vim.list_extend(deletion_proposed, vim.list_slice(deletion_original, 8, 12))
local deletion = preview.open({
  tool_call_id = "deletion-preview",
  file_path = vim.fn.getcwd() .. "/deletion.lua",
  old_content = table.concat(deletion_original, "\n"),
  new_content = table.concat(deletion_proposed, "\n"),
  unfolded_ranges = { { start_line = 5, end_line = 5 } },
})
assert(deletion.ok == true)
assert(preview.close("deletion-preview"))

-- A genuinely large change is rejected in both layouts even when its complete range is visible.
local entirely_changed = {}
for line = 1, viewport_rows + 1 do
  entirely_changed[line] = ("local replacement_%03d = true"):format(line)
end
local oversized_payload = {
  tool_call_id = "oversized-preview",
  file_path = vim.fn.getcwd() .. "/oversized.lua",
  old_content = "local original = true",
  new_content = table.concat(entirely_changed, "\n"),
  unfolded_ranges = { { start_line = 1, end_line = #entirely_changed } },
}

assert(preview.open(payload))
assert(preview.toggle_layout() == nil)
assert(vim.g.pi_diff_preview_layout == "side_by_side")
assert(preview.close(payload.tool_call_id))
local oversized_side_by_side = preview.open(oversized_payload)
assert(oversized_side_by_side.ok == false)
assert(oversized_side_by_side.reason == "preview_too_tall")
assert(oversized_side_by_side.preview_rows > oversized_side_by_side.viewport_rows)
assert(oversized_side_by_side.viewport_rows == viewport_rows)

assert(preview.open(payload))
assert(preview.toggle_layout() == nil)
assert(vim.g.pi_diff_preview_layout == "unified")
assert(preview.close(payload.tool_call_id))
oversized_payload.tool_call_id = "oversized-preview-unified"
local oversized_unified = preview.open(oversized_payload)
assert(oversized_unified.ok == false)
assert(oversized_unified.reason == "preview_too_tall")
assert(oversized_unified.preview_rows > oversized_unified.viewport_rows)
assert(oversized_unified.viewport_rows == viewport_rows)
assert(#preview_windows() == 0)
assert(vim.api.nvim_win_get_buf(original_win) == original_buf)
assert(vim.api.nvim_get_current_win() == pi_terminal_win)

vim.b[pi_terminal_buf].pi_terminal = false
local opened_without_pi, missing_pi_error = pcall(preview.open, payload)
assert(opened_without_pi == false)
assert(tostring(missing_pi_error):find("Pi terminal is not visible in the current tab", 1, true))
assert(#preview_windows() == 0)
assert(vim.api.nvim_win_get_buf(original_win) == original_buf)

-- Successful Pi mutations reload only their matching unmodified file buffers.
local temporary_directory = vim.fn.tempname()
vim.fn.mkdir(temporary_directory, "p")
local refresh_file = temporary_directory .. "/refresh.lua"
local unrelated_file = temporary_directory .. "/unrelated.lua"
vim.fn.writefile({ "refresh before" }, refresh_file)
vim.fn.writefile({ "unrelated before" }, unrelated_file)

local refresh_buf = vim.fn.bufadd(refresh_file)
local unrelated_buf = vim.fn.bufadd(unrelated_file)
vim.fn.bufload(refresh_buf)
vim.fn.bufload(unrelated_buf)
vim.fn.writefile({ "refresh updated externally" }, refresh_file)
vim.fn.writefile({ "unrelated updated externally" }, unrelated_file)

local previous_autoread = vim.o.autoread
vim.o.autoread = true
assert(preview.refresh(refresh_file))
assert(vim.api.nvim_buf_get_lines(refresh_buf, 0, 1, false)[1] == "refresh updated externally")
assert(vim.api.nvim_buf_get_lines(unrelated_buf, 0, 1, false)[1] == "unrelated before")

-- Unsaved editor changes win over an external Pi mutation.
vim.api.nvim_buf_set_lines(refresh_buf, 0, -1, false, { "unsaved editor content" })
vim.fn.writefile({ "second external update" }, refresh_file)
local notification
original_notify = vim.notify
vim.notify = function(message, level)
  notification = { message = message, level = level }
end
assert(preview.refresh(refresh_file))
vim.notify = original_notify
assert(vim.api.nvim_buf_get_lines(refresh_buf, 0, 1, false)[1] == "unsaved editor content")
assert(notification and notification.message:find("unsaved changes", 1, true))
assert(notification.level == vim.log.levels.WARN)

vim.o.autoread = previous_autoread
vim.api.nvim_buf_delete(refresh_buf, { force = true })
vim.api.nvim_buf_delete(unrelated_buf, { force = true })
vim.fn.delete(temporary_directory, "rf")

print("pi-diff-preview-spec-ok")
