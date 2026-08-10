-- Owns the interactive Pi TUI terminal and its Neovim window lifecycle.

local M = {}

-- Keep interactive terminals independent of later working-directory changes.
local interactive_terminal = nil
local worktrees = {}
local next_terminal_id = 1

--- Builds the Pi command used for a normal continuation or one-time fork.
local function terminal_command(arguments)
  local command = { vim.fn.expand("~/.config/pi/launch.zsh") }
  vim.list_extend(command, arguments or { "--continue" })
  return command
end

--- Normalizes the project directory used to identify a Pi terminal.
local function normalize_cwd(cwd)
  local root = cwd or require("config.pi.worktree").active_root() or vim.fn.getcwd()
  return vim.fn.resolve(vim.fn.fnamemodify(root, ":p")):gsub("/$", "")
end

--- Returns the Snacks terminal options for an interactive Pi session.
local function terminal_options(cwd, env, count)
  return {
    cwd = normalize_cwd(cwd),
    env = env,
    count = count,
    interactive = true,
    auto_close = false,
    win = {
      -- Edgy recognizes this buffer and moves it into the left edgebar.
      position = "right",
      width = 0.4,
      b = {
        pi_terminal = true,
      },
      wo = {
        winbar = "%{get(b:, 'pi_terminal_title', 'Pi')}",
        winfixwidth = true,
      },
    },
  }
end

--- Scrolls the current terminal window by half its visible height.
local function scroll_current_window_half_page(direction)
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  local line_count = vim.api.nvim_buf_line_count(buf)
  local height = vim.api.nvim_win_get_height(win)
  local lines = direction * math.max(1, math.floor(height / 2))
  local max_topline = math.max(1, line_count - height + 1)
  local current_topline = vim.fn.line("w0")
  local target_topline = math.max(1, math.min(max_topline, current_topline + lines))
  local target_bottom = math.min(line_count, target_topline + height - 1)
  local cursor = vim.api.nvim_win_get_cursor(win)
  local target_cursor = math.max(target_topline, math.min(target_bottom, cursor[1] + lines))

  vim.api.nvim_win_set_cursor(win, { target_cursor, cursor[2] })
  local view = vim.fn.winsaveview()
  view.topline = target_topline
  view.lnum = target_cursor
  vim.fn.winrestview(view)
end

--- Leaves terminal-input mode before manipulating Neovim's scrollback.
local function stop_terminal_insert_mode()
  if vim.fn.mode():sub(1, 1) == "t" then
    vim.cmd.stopinsert()
  end
end

--- Re-enters Pi input and forwards the Space used to resume typing.
local function resume_terminal_with_space(buf)
  vim.cmd.startinsert()
  local job_id = vim.b[buf].terminal_job_id
  if job_id then
    vim.api.nvim_chan_send(job_id, " ")
  end
end

--- Installs carrier-key mappings once for a Pi terminal buffer.
local function attach_terminal_keymaps(terminal)
  if not terminal:buf_valid() or vim.b[terminal.buf].pi_terminal_keymaps_attached then
    return
  end

  vim.b[terminal.buf].pi_terminal_keymaps_attached = true
  vim.keymap.set({ "n", "t" }, "<F18>", function()
    stop_terminal_insert_mode()
    scroll_current_window_half_page(1)
  end, {
    buffer = terminal.buf,
    silent = true,
    desc = "Pi: Scroll down half a page",
  })
  vim.keymap.set({ "n", "t" }, "<F19>", function()
    stop_terminal_insert_mode()
    scroll_current_window_half_page(-1)
  end, {
    buffer = terminal.buf,
    silent = true,
    desc = "Pi: Scroll up half a page",
  })
  vim.keymap.set({ "n", "t" }, "<F17>", function()
    local job_id = vim.b[terminal.buf].terminal_job_id
    if job_id then
      vim.api.nvim_chan_send(job_id, "/back\r")
    end
  end, {
    buffer = terminal.buf,
    silent = true,
    desc = "Pi: Abort and restore previous prompt",
  })
  vim.keymap.set("n", "<Space>", function()
    resume_terminal_with_space(terminal.buf)
  end, {
    buffer = terminal.buf,
    silent = true,
    desc = "Pi: Resume input with space",
  })
  vim.keymap.set({ "n", "t" }, "[", function()
    M.cycle_session(-1)
  end, {
    buffer = terminal.buf,
    silent = true,
    desc = "Pi: Previous session",
  })
  vim.keymap.set({ "n", "t" }, "]", function()
    M.cycle_session(1)
  end, {
    buffer = terminal.buf,
    silent = true,
    desc = "Pi: Next session",
  })
  vim.keymap.set({ "n", "t" }, "\\n", function()
    M.create_session(nil, {})
  end, {
    buffer = terminal.buf,
    silent = true,
    desc = "Pi: Add session",
  })
  vim.keymap.set({ "n", "t" }, "\\x", function()
    M.stop()
  end, {
    buffer = terminal.buf,
    silent = true,
    desc = "Pi: Close session",
  })
  for index = 1, 9 do
    local slot = index
    vim.keymap.set({ "n", "t" }, "\\" .. slot, function()
      M.switch_to_session(slot)
    end, {
      buffer = terminal.buf,
      silent = true,
      desc = "Pi: Session " .. slot,
    })
  end
end

--- Focuses a visible Pi terminal and enters terminal input mode.
local function focus_terminal(terminal)
  if terminal and terminal:win_valid() then
    terminal:focus()
    vim.cmd.startinsert()
  end
end

--- Updates the pane title stored on every terminal buffer in a worktree.
local function update_session_titles(root, worktree)
  local worktree_name = vim.fn.fnamemodify(root, ":t")
  for index, terminal in ipairs(worktree.slots) do
    if terminal:buf_valid() then
      vim.b[terminal.buf].pi_terminal_title = ("Pi: %s [%d/%d]"):format(worktree_name, index, #worktree.slots)
    end
  end
end

--- Returns the conversation slots owned by one worktree tab.
local function worktree_state(root)
  -- Each worktree remembers its ordered terminals and selected slot independently.
  local worktree = worktrees[root] or { slots = {}, active = 0 }
  worktrees[root] = worktree

  -- Buffers can be wiped outside this module, so remove stale slots before use.
  for index = #worktree.slots, 1, -1 do
    if not worktree.slots[index]:buf_valid() then
      table.remove(worktree.slots, index)
      if index <= worktree.active then
        worktree.active = worktree.active - 1
      end
    end
  end
  worktree.active = math.min(math.max(worktree.active, 1), #worktree.slots)
  update_session_titles(root, worktree)
  return worktree
end

--- Returns the selected terminal for one worktree when its buffer still exists.
local function active_terminal(root)
  local worktree = worktree_state(root)
  return worktree.slots[worktree.active]
end

--- Hides a terminal window without stopping its Pi process.
local function hide_terminal(terminal)
  if terminal and terminal:win_valid() then
    terminal:hide()
  end
end

--- Creates and focuses an independent Pi session in one worktree.
function M.create_session(cwd, arguments, env)
  local root = normalize_cwd(cwd)
  local worktree = worktree_state(root)
  hide_terminal(active_terminal(root))

  -- Snacks includes count in its cache key, so otherwise identical Pi commands
  -- receive separate terminal buffers and processes.
  local terminal_id = next_terminal_id
  next_terminal_id = next_terminal_id + 1
  local terminal = Snacks.terminal.get(terminal_command(arguments), terminal_options(root, env, terminal_id))
  if not (terminal and terminal:buf_valid()) then
    return nil
  end

  -- Appending creates the next numbered slot and selects it immediately.
  table.insert(worktree.slots, terminal)
  worktree.active = #worktree.slots
  update_session_titles(root, worktree)
  attach_terminal_keymaps(terminal)
  focus_terminal(terminal)
  interactive_terminal = terminal
  return terminal
end

--- Shows one numbered session without changing the worktree tab or editor layout.
function M.switch_to_session(index, cwd)
  local root = normalize_cwd(cwd)
  local worktree = worktree_state(root)
  local terminal = worktree.slots[index]
  if not (terminal and terminal:buf_valid()) then
    vim.notify("No Pi session in slot " .. tostring(index), vim.log.levels.WARN)
    return false
  end

  -- Only the terminal pane changes; the previous Pi process keeps running hidden.
  hide_terminal(active_terminal(root))
  worktree.active = index
  terminal:show()
  focus_terminal(terminal)
  interactive_terminal = terminal
  return true
end

--- Selects the next or previous session with wraparound.
function M.cycle_session(direction, cwd)
  local root = normalize_cwd(cwd)
  local worktree = worktree_state(root)
  if #worktree.slots == 0 then
    return false
  end
  local index = ((worktree.active - 1 + direction) % #worktree.slots) + 1
  return M.switch_to_session(index, root)
end

--- Opens and focuses the interactive Pi terminal for a project directory.
function M.open(cwd, arguments, env)
  local root = normalize_cwd(cwd)
  local worktree = worktree_state(root)
  local terminal = active_terminal(root)
  if arguments and #worktree.slots > 0 then
    error("A Pi terminal already exists for this worktree")
  end
  if not terminal then
    return M.create_session(root, arguments, env)
  end
  terminal:show()
  focus_terminal(terminal)
  interactive_terminal = terminal
  return terminal
end

--- Focuses the existing interactive Pi terminal without creating another one.
function M.focus_existing()
  local terminal = active_terminal(normalize_cwd()) or interactive_terminal
  if not (terminal and terminal:buf_valid()) then
    return false
  end
  if not terminal:win_valid() then
    terminal:show()
  end
  focus_terminal(terminal)
  interactive_terminal = terminal
  return true
end

--- Toggles the interactive Pi terminal for the current project.
function M.toggle()
  local root = normalize_cwd()
  local terminal = active_terminal(root)
  if not terminal then
    return M.create_session(root)
  end
  interactive_terminal = terminal
  terminal:toggle()
  focus_terminal(terminal)
  return terminal
end

--- Shows and focuses the interactive Pi terminal for the current project.
function M.focus()
  return M.open()
end

--- Stops the active Pi session and selects its nearest remaining neighbor.
function M.stop(cwd)
  local root = normalize_cwd(cwd)
  local worktree = worktree_state(root)
  local terminal = active_terminal(root)
  if not terminal then
    return false
  end

  terminal:close()
  table.remove(worktree.slots, worktree.active)
  update_session_titles(root, worktree)
  if #worktree.slots == 0 then
    worktrees[root] = nil
    if interactive_terminal == terminal then
      interactive_terminal = nil
    end
    return true
  end

  worktree.active = math.min(worktree.active, #worktree.slots)
  local replacement = worktree.slots[worktree.active]
  replacement:show()
  focus_terminal(replacement)
  interactive_terminal = replacement
  return true
end

--- Reports whether the current worktree's active Pi terminal is visible.
function M.is_visible()
  local terminal = active_terminal(normalize_cwd())
  return terminal ~= nil and terminal:win_valid()
end

return M
