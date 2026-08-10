-- Verifies conversation-owned Pi terminals and native Neovim tab navigation.

local original_cwd = vim.fn.getcwd()
local editor_buf = vim.api.nvim_get_current_buf()
local secondary_editor_buf = vim.api.nvim_create_buf(true, false)
vim.cmd("rightbelow vsplit")
vim.api.nvim_win_set_buf(0, secondary_editor_buf)
local requested = {}
local terminals_by_id = {}

--- Creates a fake Snacks terminal with independent process and window state.
local function new_terminal()
  local terminal = {
    buf = vim.api.nvim_create_buf(false, true),
    visible = true,
    show_count = 1,
    focus_count = 0,
    close_count = 0,
  }

  function terminal:buf_valid()
    return vim.api.nvim_buf_is_valid(self.buf)
  end

  function terminal:win_valid()
    return self.visible
  end

  function terminal:show()
    self.visible = true
    self.show_count = self.show_count + 1
    return self
  end

  function terminal:toggle()
    self.visible = not self.visible
    return self
  end

  function terminal:focus()
    self.focus_count = self.focus_count + 1
    return self
  end

  function terminal:close()
    self.visible = false
    self.close_count = self.close_count + 1
  end

  return terminal
end

Snacks = {
  terminal = {
    get = function(command, opts)
      local id = vim.inspect({ command = command, cwd = opts.cwd, env = opts.env, count = opts.count })
      local terminal = terminals_by_id[id]
      local created = terminal == nil
      if created then
        terminal = new_terminal()
        terminals_by_id[id] = terminal
      end
      table.insert(requested, { command = command, options = opts, terminal = terminal, created = created })
      return terminal, created
    end,
  },
}

local pi_terminal = require("config.pi.terminal")
local first_tab = vim.api.nvim_get_current_tabpage()
local first = pi_terminal.open()
local first_request = requested[1]
assert(first_request.command[2] == "--continue")
assert(first_request.options.cwd == original_cwd)
assert(first_request.options.count == 1)
assert(first_request.options.win.wo.winbar == "%{get(b:, 'pi_terminal_title', 'Pi')}")
assert(first.focus_count == 1)

-- Every Pi buffer receives terminal-local conversation controls.
local expected_mappings = {
  ["<F17>"] = "Pi: Abort and restore previous prompt",
  ["<F18>"] = "Pi: Scroll down half a page",
  ["<F19>"] = "Pi: Scroll up half a page",
  ["["] = "Pi: Previous session",
  ["]"] = "Pi: Next session",
  ["\\n"] = "Pi: Add session",
  ["\\x"] = "Pi: Close session",
  ["\\1"] = "Pi: Session 1",
}
vim.api.nvim_buf_call(first.buf, function()
  for lhs, description in pairs(expected_mappings) do
    local mode = lhs == "<Space>" and "n" or "t"
    assert(vim.fn.maparg(lhs, mode, false, true).desc == description)
  end
end)
assert(vim.b[first.buf].pi_terminal_keymaps_attached == true)

-- A fresh conversation copies the editor context into a distinct native tab.
local second = pi_terminal.create_session(nil, {})
local second_tab = vim.api.nvim_get_current_tabpage()
local second_request = requested[2]
assert(second_tab ~= first_tab)
local copied_buffers = {}
for _, win in ipairs(vim.api.nvim_tabpage_list_wins(second_tab)) do
  copied_buffers[vim.api.nvim_win_get_buf(win)] = true
end
assert(copied_buffers[editor_buf])
assert(copied_buffers[secondary_editor_buf])
assert(#second_request.command == 1)
assert(second_request.options.count == 2)
assert(second ~= first)
assert(first.visible and second.visible)
local worktree_name = vim.fn.fnamemodify(original_cwd, ":t")
assert(vim.b[first.buf].pi_terminal_title == "Pi: " .. worktree_name .. " [1/2]")
assert(vim.b[second.buf].pi_terminal_title == "Pi: " .. worktree_name .. " [2/2]")

-- Native tab navigation updates the conversation used by global focus fallback.
vim.api.nvim_set_current_tabpage(first_tab)
local native_fallback_tab
vim.cmd.tabnew()
native_fallback_tab = vim.api.nvim_get_current_tabpage()
assert(pi_terminal.focus_existing())
assert(vim.api.nvim_get_current_tabpage() == first_tab)
vim.cmd("tabclose " .. vim.api.nvim_tabpage_get_number(native_fallback_tab))

-- Global navigation changes the complete browsing tab, not only the terminal pane.
assert(pi_terminal.switch_to_session(1))
assert(vim.api.nvim_get_current_tabpage() == first_tab)
local restored_buffers = {}
for _, win in ipairs(vim.api.nvim_tabpage_list_wins(first_tab)) do
  restored_buffers[vim.api.nvim_win_get_buf(win)] = true
end
assert(restored_buffers[editor_buf])
assert(restored_buffers[secondary_editor_buf])
assert(pi_terminal.cycle_session(-1))
assert(vim.api.nvim_get_current_tabpage() == second_tab)
assert(pi_terminal.cycle_session(1))
assert(vim.api.nvim_get_current_tabpage() == first_tab)
assert(not pi_terminal.switch_to_session(9))

local ordinary_tab
vim.cmd.tabnew()
ordinary_tab = vim.api.nvim_get_current_tabpage()
assert(pi_terminal.cycle_session(1))
assert(vim.api.nvim_get_current_tabpage() == first_tab)
vim.cmd("tabclose " .. vim.api.nvim_tabpage_get_number(ordinary_tab))
vim.cmd.tabnew()
ordinary_tab = vim.api.nvim_get_current_tabpage()
assert(pi_terminal.cycle_session(-1))
assert(vim.api.nvim_get_current_tabpage() == second_tab)
vim.cmd("tabclose " .. vim.api.nvim_tabpage_get_number(ordinary_tab))

local sessions = pi_terminal.list_sessions()
assert(#sessions == 2)
assert(sessions[1].tabpage == first_tab)
assert(sessions[2].tabpage == second_tab)
assert(sessions[1].root == sessions[2].root)

-- One-time session arguments cannot replace the conversation in an occupied tab.
local occupied_ok, occupied_err = pcall(pi_terminal.open, original_cwd, { "--session", "/tmp/other.jsonl" })
assert(not occupied_ok)
assert(tostring(occupied_err):find("already exists", 1, true))

-- Native tab closure stops the otherwise unreachable Pi process and renumbers peers.
assert(pi_terminal.switch_to_session(2))
vim.cmd.tabclose()
vim.wait(50, function()
  return second.close_count == 1
end)
assert(second.close_count == 1)
assert(#pi_terminal.list_sessions() == 1)
assert(vim.b[first.buf].pi_terminal_title == "Pi: " .. worktree_name .. " [1/1]")
local fallback_tab
vim.cmd.tabnew()
fallback_tab = vim.api.nvim_get_current_tabpage()
assert(pi_terminal.focus_existing())
assert(vim.api.nvim_get_current_tabpage() == first_tab)
vim.cmd("tabclose " .. vim.api.nvim_tabpage_get_number(fallback_tab))

-- The explicit close command closes its conversation tab and selects its neighbor.
local replacement = pi_terminal.create_session(nil, {})
local replacement_tab = vim.api.nvim_get_current_tabpage()
assert(pi_terminal.stop())
assert(replacement.close_count == 1)
assert(not vim.api.nvim_tabpage_is_valid(replacement_tab))
assert(vim.api.nvim_get_current_tabpage() == first_tab)
assert(pi_terminal.stop())
assert(first.close_count == 1)
assert(not pi_terminal.stop())

-- Editor mappings expose the same unified conversation navigation.
local plugin_spec = dofile(original_cwd .. "/lua/plugins/ai.lua")
local mappings = {}
for _, mapping in ipairs(plugin_spec[1].keys) do
  mappings[mapping[1]] = mapping
end
assert(mappings["<leader>ca"].desc == "Pi: Add session")
assert(mappings["<leader>cx"].desc == "Pi: Close session")
assert(mappings["<leader>cn"].desc == "Pi: Next session")
assert(mappings["<leader>ce"].desc == "Pi: Previous session")
for index = 1, 9 do
  assert(mappings["<leader>c" .. index].desc == "Pi: Session " .. index)
end

print("pi-terminal-spec-ok")
