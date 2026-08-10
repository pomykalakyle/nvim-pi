-- Owns Pi conversations, their terminal processes, and native Neovim tabs.

local M = {}

local interactive_terminal = nil
local conversations = {}
local next_terminal_id = 1

--- Builds the Pi command used for a normal continuation or one-time fork.
local function terminal_command(arguments)
  local command = { vim.fn.expand("~/.config/pi/launch.zsh") }
  vim.list_extend(command, arguments or { "--continue" })
  return command
end

--- Normalizes the worktree directory assigned to a conversation tab.
local function normalize_cwd(cwd)
  local root = cwd or require("config.pi.worktree").active_root() or vim.fn.getcwd()
  return vim.fn.resolve(vim.fn.fnamemodify(root, ":p")):gsub("/$", "")
end

--- Returns the Snacks options for an independent Pi terminal process.
local function terminal_options(cwd, env, count)
  return {
    cwd = normalize_cwd(cwd),
    env = env,
    count = count,
    interactive = true,
    auto_close = false,
    win = {
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

--- Removes conversations whose terminal buffer or native tab no longer exists.
local function valid_conversations()
  local removed_interactive = false
  for index = #conversations, 1, -1 do
    local conversation = conversations[index]
    if not conversation.terminal:buf_valid() or not vim.api.nvim_tabpage_is_valid(conversation.tabpage) then
      removed_interactive = removed_interactive or interactive_terminal == conversation.terminal
      if conversation.terminal:buf_valid() then
        conversation.terminal:close()
      end
      table.remove(conversations, index)
    end
  end

  if removed_interactive then
    interactive_terminal = nil
    local current_tab = vim.api.nvim_get_current_tabpage()
    for _, conversation in ipairs(conversations) do
      if conversation.tabpage == current_tab then
        interactive_terminal = conversation.terminal
        break
      end
    end
    interactive_terminal = interactive_terminal
      or (conversations[#conversations] and conversations[#conversations].terminal)
  end
  return conversations
end

--- Returns the conversation attached to one native tabpage.
local function conversation_for_tab(tabpage)
  for index, conversation in ipairs(valid_conversations()) do
    if conversation.tabpage == tabpage then
      return conversation, index
    end
  end
  return nil
end

--- Updates every visible terminal label from the unified conversation order.
local function update_conversation_titles()
  local total = #valid_conversations()
  for index, conversation in ipairs(conversations) do
    local worktree = vim.fn.fnamemodify(conversation.root, ":t")
    vim.b[conversation.terminal.buf].pi_terminal_title = ("Pi: %s [%d/%d]"):format(worktree, index, total)
  end
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

--- Focuses a visible Pi terminal and enters terminal input mode.
local function focus_terminal(terminal)
  if terminal and terminal:win_valid() then
    terminal:focus()
    vim.cmd.startinsert()
  end
end

--- Installs conversation controls on one Pi terminal buffer.
local function attach_terminal_keymaps(terminal)
  if not terminal:buf_valid() or vim.b[terminal.buf].pi_terminal_keymaps_attached then
    return
  end

  vim.b[terminal.buf].pi_terminal_keymaps_attached = true
  vim.keymap.set({ "n", "t" }, "<F18>", function()
    stop_terminal_insert_mode()
    scroll_current_window_half_page(1)
  end, { buffer = terminal.buf, silent = true, desc = "Pi: Scroll down half a page" })
  vim.keymap.set({ "n", "t" }, "<F19>", function()
    stop_terminal_insert_mode()
    scroll_current_window_half_page(-1)
  end, { buffer = terminal.buf, silent = true, desc = "Pi: Scroll up half a page" })
  vim.keymap.set({ "n", "t" }, "<F17>", function()
    local job_id = vim.b[terminal.buf].terminal_job_id
    if job_id then
      vim.api.nvim_chan_send(job_id, "/back\r")
    end
  end, { buffer = terminal.buf, silent = true, desc = "Pi: Abort and restore previous prompt" })
  vim.keymap.set("n", "<Space>", function()
    resume_terminal_with_space(terminal.buf)
  end, { buffer = terminal.buf, silent = true, desc = "Pi: Resume input with space" })
  vim.keymap.set({ "n", "t" }, "[", function()
    M.cycle_session(-1)
  end, { buffer = terminal.buf, silent = true, desc = "Pi: Previous session" })
  vim.keymap.set({ "n", "t" }, "]", function()
    M.cycle_session(1)
  end, { buffer = terminal.buf, silent = true, desc = "Pi: Next session" })
  vim.keymap.set({ "n", "t" }, "\\n", function()
    M.create_session(nil, {})
  end, { buffer = terminal.buf, silent = true, desc = "Pi: Add session" })
  vim.keymap.set({ "n", "t" }, "\\x", function()
    M.stop()
  end, { buffer = terminal.buf, silent = true, desc = "Pi: Close session" })
  for index = 1, 9 do
    local slot = index
    vim.keymap.set({ "n", "t" }, "\\" .. slot, function()
      M.switch_to_session(slot)
    end, { buffer = terminal.buf, silent = true, desc = "Pi: Session " .. slot })
  end
end

--- Starts a Pi process and attaches it to the current native tabpage.
local function create_in_current_tab(root, arguments, env)
  local tabpage = vim.api.nvim_get_current_tabpage()
  if conversation_for_tab(tabpage) then
    error("A Pi conversation already exists in this tab")
  end

  local terminal_id = next_terminal_id
  next_terminal_id = next_terminal_id + 1
  local terminal = Snacks.terminal.get(terminal_command(arguments), terminal_options(root, env, terminal_id))
  if not (terminal and terminal:buf_valid()) then
    return nil
  end

  table.insert(conversations, {
    root = root,
    tabpage = tabpage,
    terminal = terminal,
  })
  attach_terminal_keymaps(terminal)
  update_conversation_titles()
  focus_terminal(terminal)
  interactive_terminal = terminal
  return terminal
end

--- Creates a copied-layout conversation tab in the current worktree.
function M.create_session(cwd, arguments, env)
  local root = normalize_cwd(cwd)
  local tabpage, err = require("config.pi.worktree").clone_current_tab(root)
  if not tabpage then
    vim.notify(err, vim.log.levels.ERROR, { title = "Pi" })
    return nil
  end

  local opened, terminal = pcall(create_in_current_tab, root, arguments, env)
  if not opened or not terminal then
    if vim.api.nvim_tabpage_is_valid(tabpage) then
      vim.cmd("tabclose " .. vim.api.nvim_tabpage_get_number(tabpage))
    end
    if not opened then
      error(terminal)
    end
    return nil
  end
  return terminal
end

--- Switches to one conversation tab from the unified project-wide list.
function M.switch_to_session(index)
  local conversation = valid_conversations()[index]
  if not conversation then
    vim.notify("No Pi session in slot " .. tostring(index), vim.log.levels.WARN)
    return false
  end

  vim.api.nvim_set_current_tabpage(conversation.tabpage)
  if not conversation.terminal:win_valid() then
    conversation.terminal:show()
  end
  focus_terminal(conversation.terminal)
  interactive_terminal = conversation.terminal
  return true
end

--- Selects the next or previous conversation with wraparound.
function M.cycle_session(direction)
  local _, current = conversation_for_tab(vim.api.nvim_get_current_tabpage())
  local total = #valid_conversations()
  if total == 0 then
    return false
  end
  if not current then
    return M.switch_to_session(direction < 0 and total or 1)
  end
  return M.switch_to_session(((current - 1 + direction) % total) + 1)
end

--- Opens Pi in the current browsing tab or focuses its existing conversation.
function M.open(cwd, arguments, env)
  local root = normalize_cwd(cwd)
  local conversation = conversation_for_tab(vim.api.nvim_get_current_tabpage())
  if conversation then
    if arguments then
      error("A Pi conversation already exists in this tab")
    end
    if not conversation.terminal:win_valid() then
      conversation.terminal:show()
    end
    focus_terminal(conversation.terminal)
    interactive_terminal = conversation.terminal
    return conversation.terminal
  end
  return create_in_current_tab(root, arguments, env)
end

--- Focuses the current tab's conversation or the most recently used one.
function M.focus_existing()
  local conversation = conversation_for_tab(vim.api.nvim_get_current_tabpage())
  local terminal = conversation and conversation.terminal or interactive_terminal
  if not (terminal and terminal:buf_valid()) then
    return false
  end
  if not conversation then
    for index, candidate in ipairs(valid_conversations()) do
      if candidate.terminal == terminal then
        return M.switch_to_session(index)
      end
    end
  end
  if not terminal:win_valid() then
    terminal:show()
  end
  focus_terminal(terminal)
  interactive_terminal = terminal
  return true
end

--- Toggles the Pi terminal owned by the current conversation tab.
function M.toggle()
  local conversation = conversation_for_tab(vim.api.nvim_get_current_tabpage())
  if not conversation then
    return M.open()
  end
  interactive_terminal = conversation.terminal
  conversation.terminal:toggle()
  focus_terminal(conversation.terminal)
  return conversation.terminal
end

--- Shows and focuses Pi in the current conversation tab.
function M.focus()
  return M.open()
end

--- Stops the current conversation, closes its tab, and selects its neighbor.
function M.stop()
  local conversation, index = conversation_for_tab(vim.api.nvim_get_current_tabpage())
  if not conversation then
    return false
  end

  conversation.terminal:close()
  table.remove(conversations, index)
  local replacement = conversations[math.min(index, #conversations)] or conversations[index - 1]
  if #vim.api.nvim_list_tabpages() > 1 and vim.api.nvim_tabpage_is_valid(conversation.tabpage) then
    vim.cmd("tabclose " .. vim.api.nvim_tabpage_get_number(conversation.tabpage))
  end
  update_conversation_titles()
  if replacement and vim.api.nvim_tabpage_is_valid(replacement.tabpage) then
    vim.api.nvim_set_current_tabpage(replacement.tabpage)
    focus_terminal(replacement.terminal)
    interactive_terminal = replacement.terminal
  elseif interactive_terminal == conversation.terminal then
    interactive_terminal = nil
  end
  return true
end

--- Reports whether the current tab's Pi terminal is visible.
function M.is_visible()
  local conversation = conversation_for_tab(vim.api.nvim_get_current_tabpage())
  return conversation ~= nil and conversation.terminal:win_valid()
end

--- Returns conversation metadata for unified navigation and pickers.
function M.list_sessions()
  update_conversation_titles()
  local items = {}
  for index, conversation in ipairs(conversations) do
    items[index] = {
      index = index,
      root = conversation.root,
      tabpage = conversation.tabpage,
      title = vim.b[conversation.terminal.buf].pi_terminal_title,
    }
  end
  return items
end

local lifecycle_group = vim.api.nvim_create_augroup("PiConversationTabs", { clear = true })
vim.api.nvim_create_autocmd("TabClosed", {
  group = lifecycle_group,
  callback = function()
    vim.schedule(update_conversation_titles)
  end,
})
vim.api.nvim_create_autocmd("TabEnter", {
  group = lifecycle_group,
  callback = function()
    local conversation = conversation_for_tab(vim.api.nvim_get_current_tabpage())
    if conversation then
      interactive_terminal = conversation.terminal
    end
  end,
})

return M
