-- Verifies the lifecycle and launch contract of the interactive Pi terminal.

local requested_command = nil
local requested_options = nil
local get_count = 0

local terminal = {
  buf = vim.api.nvim_get_current_buf(),
  visible = false,
  show_count = 0,
  focus_count = 0,
  close_count = 0,
}

--- Reports whether the fake terminal buffer is valid.
function terminal:buf_valid()
  return vim.api.nvim_buf_is_valid(self.buf)
end

--- Reports whether the fake terminal window is visible.
function terminal:win_valid()
  return self.visible
end

--- Shows the fake terminal window.
function terminal:show()
  self.visible = true
  self.show_count = self.show_count + 1
  return self
end

--- Hides or shows the fake terminal window.
function terminal:toggle()
  self.visible = not self.visible
  return self
end

--- Records focus on the fake terminal window.
function terminal:focus()
  self.focus_count = self.focus_count + 1
  return self
end

--- Closes the fake terminal process and window.
function terminal:close()
  self.visible = false
  self.close_count = self.close_count + 1
end

Snacks = {
  terminal = {
    --- Returns the reusable fake Pi terminal.
    get = function(command, opts)
      get_count = get_count + 1
      requested_command = command
      requested_options = opts
      if opts.create == false and terminal.close_count > 0 then
        return nil, false
      end
      local created = terminal.show_count == 0
      if created then
        terminal:show()
      end
      return terminal, created
    end,
  },
}

local pi_terminal = require("config.pi.terminal")
pi_terminal.open()

local launch = table.concat(requested_command, " ")
assert(requested_command[1]:match("/%.config/pi/launch%.zsh$"))
assert(launch:find("--continue", 1, true))
assert(not launch:find("--mode", 1, true))
assert(not launch:find("rpc", 1, true))
assert(requested_options.win.position == "right")
assert(requested_options.win.b.pi_terminal == true)
assert(terminal.visible)
assert(terminal.focus_count == 1)

local rewind_normal = vim.fn.maparg("<F17>", "n", false, true)
local rewind_terminal = vim.fn.maparg("<F17>", "t", false, true)
local scroll_down = vim.fn.maparg("<F18>", "n", false, true)
local scroll_up = vim.fn.maparg("<F19>", "t", false, true)
local resume_space = vim.fn.maparg("<Space>", "n", false, true)
assert(rewind_normal.buffer == 1)
assert(rewind_normal.desc == "Pi: Abort and restore previous prompt")
assert(rewind_terminal.buffer == 1)
assert(rewind_terminal.desc == "Pi: Abort and restore previous prompt")
assert(scroll_down.buffer == 1)
assert(scroll_down.desc == "Pi: Scroll down half a page")
assert(scroll_up.buffer == 1)
assert(scroll_up.desc == "Pi: Scroll up half a page")
assert(resume_space.buffer == 1)
assert(resume_space.desc == "Pi: Resume input with space")
assert(vim.b[terminal.buf].pi_terminal_keymaps_attached == true)

pi_terminal.toggle()
assert(not terminal.visible)

local get_count_before_focus = get_count
local alternate_cwd = vim.fn.tempname()
vim.fn.mkdir(alternate_cwd, "p")
vim.cmd("lcd " .. vim.fn.fnameescape(alternate_cwd))
assert(pi_terminal.focus_existing())
assert(terminal.visible)
assert(terminal.focus_count == 2)
assert(get_count == get_count_before_focus)

assert(pi_terminal.is_visible())
assert(pi_terminal.stop())
assert(not terminal.visible)
assert(terminal.close_count == 1)
assert(not pi_terminal.stop())

print("pi-terminal-spec-ok")
