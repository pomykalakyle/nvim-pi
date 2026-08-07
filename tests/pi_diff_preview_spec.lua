-- Verifies the read-only Neovim display used for Pi edit proposals.

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
vim.g.pi_diff_preview_layout = "side_by_side"

local inline_compute_count = 0
local inline_render_count = 0
local inline_clear_count = 0
local inline_render_error

package.loaded["lazy"] = {
  load = function(options)
    assert(vim.deep_equal(options.plugins, { "codediff.nvim" }))
  end,
}

package.loaded["codediff.core.diff"] = {
  compute_diff = function(original_lines, proposed_lines, options)
    inline_compute_count = inline_compute_count + 1
    assert(original_lines[1] == 'local value = "before"')
    assert(proposed_lines[1] == 'local value = "after"')
    assert(options.max_computation_time_ms == 5000)
    return { changes = {}, moves = {} }
  end,
}

package.loaded["codediff.ui.inline"] = {
  render_inline_diff = function(buf, result, original_lines, proposed_lines, options)
    inline_render_count = inline_render_count + 1
    if inline_render_error then
      error(inline_render_error)
    end
    assert(vim.api.nvim_buf_is_valid(buf))
    assert(type(result.changes) == "table")
    assert(original_lines[1] == 'local value = "before"')
    assert(proposed_lines[1] == 'local value = "after"')
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
assert(preview.open(payload))

local windows = preview_windows()
assert(#windows == 2)
local preview_before_win = assert(find_preview_window("/original/"))
local preview_proposed_win = assert(find_preview_window("/proposed/"))
local preview_before_buf = vim.api.nvim_win_get_buf(preview_before_win)
local preview_proposed_buf = vim.api.nvim_win_get_buf(preview_proposed_win)
assert(vim.wo[preview_before_win].diff == true)
assert(vim.wo[preview_proposed_win].diff == true)
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
assert(vim.wo[preview_before_win].diff == true)
assert(vim.wo[preview_proposed_win].diff == true)
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

-- A proposal taller than the live editor viewport is rejected and fully cleaned up.
local viewport_rows = vim.api.nvim_win_get_height(original_win)
local oversized_lines = {}
for line = 1, viewport_rows + 1 do
  oversized_lines[line] = ("local oversized_%03d = %d"):format(line, line)
end
local oversized = preview.open({
  tool_call_id = "oversized-preview",
  file_path = vim.fn.getcwd() .. "/oversized.lua",
  old_content = table.concat(oversized_lines, "\n"),
  new_content = table.concat(oversized_lines, "\n") .. "\nlocal added = true",
})
assert(oversized.ok == false)
assert(oversized.reason == "preview_too_tall")
assert(oversized.preview_rows > oversized.viewport_rows)
assert(oversized.viewport_rows == viewport_rows)
assert(#preview_windows() == 0)
assert(vim.api.nvim_win_get_buf(original_win) == original_buf)
assert(vim.api.nvim_get_current_win() == pi_terminal_win)

-- The temporary feature flag keeps oversized previews available while compact sizing is unfinished.
vim.g.pi_diff_preview_enforce_fit = false
local oversized_allowed = preview.open({
  tool_call_id = "oversized-preview-allowed",
  file_path = vim.fn.getcwd() .. "/oversized.lua",
  old_content = table.concat(oversized_lines, "\n"),
  new_content = table.concat(oversized_lines, "\n") .. "\nlocal added = true",
})
assert(oversized_allowed.ok == true)
assert(oversized_allowed.preview_rows > oversized_allowed.viewport_rows)
assert(#preview_windows() == 2)
assert(preview.close("oversized-preview-allowed"))
vim.g.pi_diff_preview_enforce_fit = nil

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
local original_notify = vim.notify
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
