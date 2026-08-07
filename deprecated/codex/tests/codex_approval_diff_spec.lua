-- Deprecated Codex-only test retained for migration reference.
--[=[
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
vim.g.codex_approval_diff_layout = nil

local inline_compute_count = 0
local inline_render_count = 0
local inline_clear_count = 0

package.loaded["neo-tree.command"] = {
  ---Ignore Neo-tree reveals during the focused approval diff test.
  execute = function() end,
}

package.loaded["lazy"] = {
  ---Verify that the approval preview requests the configured CodeDiff plugin.
  load = function(options)
    assert(vim.deep_equal(options.plugins, { "codediff.nvim" }))
  end,
}

package.loaded["codediff.core.diff"] = {
  ---Return a deterministic changed-line mapping for the inline renderer.
  compute_diff = function(original_lines, modified_lines)
    inline_compute_count = inline_compute_count + 1
    assert(original_lines[1] == 'local value = "old"')
    assert(modified_lines[1] == 'local value = "new"')
    return {
      changes = {
        {
          original = { start_line = 1, end_line = 2 },
          modified = { start_line = 1, end_line = 2 },
          inner_changes = {},
        },
      },
      moves = {},
    }
  end,
}

package.loaded["codediff.ui.inline"] = {
  ---Record a CodeDiff inline render without depending on its native test library.
  render_inline_diff = function(bufnr, diff_result, original_lines, modified_lines, options)
    inline_render_count = inline_render_count + 1
    assert(vim.api.nvim_buf_is_valid(bufnr))
    assert(#diff_result.changes == 1)
    assert(original_lines[1] == 'local value = "old"')
    assert(modified_lines[1] == 'local value = "new"')
    assert(options.filetype == "lua")
  end,

  ---Record removal of CodeDiff's inline decorations.
  clear = function(bufnr)
    inline_clear_count = inline_clear_count + 1
    assert(vim.api.nvim_buf_is_valid(bufnr))
  end,
}

---Return all visible windows managed by the Codex approval diff.
local function approval_windows()
  local windows = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local ok, value = pcall(vim.api.nvim_win_get_var, win, "codex_approval_diff")
    if ok and value == true then
      windows[#windows + 1] = win
    end
  end
  return windows
end

---Return the approval window whose buffer name includes the requested fragment.
local function find_approval_window(fragment)
  for _, win in ipairs(approval_windows()) do
    local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
    if name:find(fragment, 1, true) then
      return win
    end
  end
end

local original_win = vim.api.nvim_get_current_win()
local original_buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(original_buf, 0, -1, false, { "original buffer" })

local preview_path = vim.fn.tempname()
vim.fn.writefile({
  vim.json.encode({
    tool_use_id = "toggle-test",
    old_path = vim.fn.getcwd() .. "/example.lua",
    new_path = vim.fn.getcwd() .. "/example.lua",
    old_content = 'local value = "old"\nreturn value\n',
    new_content = 'local value = "new"\nreturn value\n',
  }),
}, preview_path)

local approval_diff = require("config.codex_approval_diff")
assert(approval_diff.open_from_file(preview_path))

local side_windows = approval_windows()
assert(#side_windows == 2)
local old_win = assert(find_approval_window("/old/"))
local new_win = assert(find_approval_window("/new/"))
local new_buf = vim.api.nvim_win_get_buf(new_win)
assert(vim.wo[old_win].diff == true)
assert(vim.wo[new_win].diff == true)

vim.api.nvim_set_current_win(old_win)
local toggle_mapping = vim.fn.maparg("t", "n", false, true)
assert(toggle_mapping.buffer == 1)
assert(toggle_mapping.desc == "Codex: Toggle diff layout")

vim.cmd("CodexDiffToggle")
local unified_windows = approval_windows()
assert(#unified_windows == 1)
local unified_win = unified_windows[1]
local unified_buf = vim.api.nvim_win_get_buf(unified_win)
assert(unified_buf == new_buf)
assert(vim.bo[unified_buf].filetype == "lua")
assert(vim.wo[unified_win].diff == false)
assert(inline_compute_count == 1)
assert(inline_render_count == 1)

vim.api.nvim_feedkeys("t", "x", false)
assert(#approval_windows() == 2)
old_win = assert(find_approval_window("/old/"))
new_win = assert(find_approval_window("/new/"))
assert(vim.wo[old_win].diff == true)
assert(vim.wo[new_win].diff == true)
assert(inline_clear_count == 1)

vim.cmd("CodexDiffToggle")
assert(#approval_windows() == 1)
assert(inline_compute_count == 1)
assert(inline_render_count == 2)
assert(approval_diff.restore_preview())
assert(#approval_windows() == 0)
assert(inline_clear_count == 2)
assert(vim.api.nvim_win_is_valid(original_win))
assert(vim.api.nvim_win_get_buf(original_win) == original_buf)
assert(vim.api.nvim_buf_get_lines(original_buf, 0, -1, false)[1] == "original buffer")

assert(vim.g.codex_approval_diff_layout == "unified")
assert(approval_diff.open_from_file(preview_path))
assert(#approval_windows() == 1)
assert(inline_compute_count == 2)
assert(inline_render_count == 3)

vim.cmd("CodexDiffToggle")
assert(vim.g.codex_approval_diff_layout == "side_by_side")
assert(#approval_windows() == 2)
assert(approval_diff.restore_preview())

assert(approval_diff.open_from_file(preview_path))
assert(#approval_windows() == 2)
assert(approval_diff.restore_preview())

vim.fn.delete(preview_path)
print("codex-approval-diff-spec-ok")
]=]
