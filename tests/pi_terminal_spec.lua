-- Verifies the lifecycle and launch contract of interactive Pi terminal slots.

local original_cwd = vim.fn.getcwd()
local requested = {}
local terminals_by_id = {}

--- Creates a fake Snacks terminal with its own Neovim buffer and window state.
local function new_terminal()
  local terminal = {
    buf = vim.api.nvim_create_buf(false, true),
    visible = true,
    show_count = 1,
    hide_count = 0,
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

  function terminal:hide()
    self.visible = false
    self.hide_count = self.hide_count + 1
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
    --- Reuses terminals only when command, cwd, environment, and count match.
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
local first = pi_terminal.open()
local first_request = requested[1]

assert(first_request.command[1]:match("/%.config/pi/launch%.zsh$"))
assert(first_request.command[2] == "--continue")
assert(first_request.options.cwd == original_cwd)
assert(first_request.options.count == 1)
assert(first_request.options.win.position == "right")
assert(first_request.options.win.b.pi_terminal == true)
assert(first_request.options.win.wo.winbar == "%{get(b:, 'pi_terminal_title', 'Pi')}")
assert(first.visible)
assert(first.focus_count == 1)

vim.api.nvim_set_current_buf(first.buf)
local rewind_normal = vim.fn.maparg("<F17>", "n", false, true)
local rewind_terminal = vim.fn.maparg("<F17>", "t", false, true)
local scroll_down = vim.fn.maparg("<F18>", "n", false, true)
local scroll_up = vim.fn.maparg("<F19>", "t", false, true)
local resume_space = vim.fn.maparg("<Space>", "n", false, true)
local previous_session = vim.fn.maparg("[", "t", false, true)
local next_session = vim.fn.maparg("]", "t", false, true)
local add_session = vim.fn.maparg("\\n", "t", false, true)
local close_session = vim.fn.maparg("\\x", "t", false, true)
local select_session = vim.fn.maparg("\\1", "t", false, true)
assert(rewind_normal.desc == "Pi: Abort and restore previous prompt")
assert(rewind_terminal.desc == "Pi: Abort and restore previous prompt")
assert(scroll_down.desc == "Pi: Scroll down half a page")
assert(scroll_up.desc == "Pi: Scroll up half a page")
assert(resume_space.desc == "Pi: Resume input with space")
assert(previous_session.desc == "Pi: Previous session")
assert(next_session.desc == "Pi: Next session")
assert(add_session.desc == "Pi: Add session")
assert(close_session.desc == "Pi: Close session")
assert(select_session.desc == "Pi: Session 1")
assert(vim.b[first.buf].pi_terminal_keymaps_attached == true)

-- A fresh session has no --continue argument and hides, but does not stop, its neighbor.
local second = pi_terminal.create_session(nil, {})
local second_request = requested[2]
assert(#second_request.command == 1)
assert(second_request.options.count == 2)
assert(second ~= first)
assert(not first.visible)
assert(first.hide_count == 1)
assert(first.close_count == 0)
assert(second.visible)
assert(vim.b[second.buf].pi_terminal_keymaps_attached == true)
local worktree_name = vim.fn.fnamemodify(original_cwd, ":t")
assert(vim.b[first.buf].pi_terminal_title == "Pi: " .. worktree_name .. " [1/2]")
assert(vim.b[second.buf].pi_terminal_title == "Pi: " .. worktree_name .. " [2/2]")

assert(pi_terminal.switch_to_session(1))
assert(first.visible)
assert(not second.visible)
assert(pi_terminal.cycle_session(-1))
assert(second.visible)
assert(pi_terminal.cycle_session(1))
assert(first.visible)
assert(not pi_terminal.switch_to_session(9))

-- Closing one slot preserves its neighbor and selects it in the same worktree.
assert(pi_terminal.stop())
assert(first.close_count == 1)
assert(second.visible)
assert(second.close_count == 0)
assert(pi_terminal.stop())
assert(second.close_count == 1)
assert(not pi_terminal.stop())

-- Simultaneous worktrees retain independent slot lists.
local retained = pi_terminal.open(original_cwd)
local fork_root = vim.fn.tempname()
vim.fn.mkdir(fork_root, "p")
local forked = pi_terminal.open(fork_root, { "--fork", "/tmp/source-session.jsonl" })
local fork_request = requested[#requested]
assert(fork_request.command[2] == "--fork")
assert(fork_request.command[3] == "/tmp/source-session.jsonl")
local normalized_fork_root = vim.fn.resolve(vim.fn.fnamemodify(fork_root, ":p")):gsub("/$", "")
assert(fork_request.options.cwd == normalized_fork_root)
assert(forked.visible)
assert(pi_terminal.open(fork_root) == forked)
assert(pi_terminal.switch_to_session(1, original_cwd))
assert(retained.visible)
assert(pi_terminal.switch_to_session(1, fork_root))
assert(forked.visible)
local occupied_ok, occupied_err = pcall(pi_terminal.open, fork_root, { "--session", "/tmp/other.jsonl" })
assert(not occupied_ok)
assert(tostring(occupied_err):find("already exists", 1, true))

-- Wiped terminal buffers are removed before slot selection.
local stale = pi_terminal.create_session(original_cwd, {})
vim.api.nvim_buf_delete(stale.buf, { force = true })
assert(pi_terminal.open(original_cwd) == retained)
assert(not pi_terminal.switch_to_session(2, original_cwd))

-- Implicit operations use the tab's worktree root, not a window-local cwd.
vim.api.nvim_tabpage_set_var(0, "pi_worktree_root", original_cwd)
local alternate_cwd = vim.fn.tempname()
vim.fn.mkdir(alternate_cwd, "p")
vim.cmd("lcd " .. vim.fn.fnameescape(alternate_cwd))
local added_from_alternate_cwd = pi_terminal.create_session(nil, {})
assert(pi_terminal.switch_to_session(1))
assert(retained.visible)
assert(pi_terminal.switch_to_session(2))
assert(added_from_alternate_cwd.visible)

-- The plugin exposes every slot control and disables LazyVim's conflicting mapping.
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
local lsp_keys = plugin_spec[3].opts.servers["*"].keys
assert(lsp_keys[1][1] == "<leader>ca" and lsp_keys[1][2] == false)

print("pi-terminal-spec-ok")
