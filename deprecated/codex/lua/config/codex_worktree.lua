-- Deprecated Codex-only implementation retained for migration reference.
--[=[
local M = {}

local git_worktree = require("config.git_worktree")
local contexts = {}
local pending_handoffs = {}
local setup_complete = false

--- Returns the Codex terminal provider when it is available.
local function terminal_provider()
  local ok, provider = pcall(require, "config.codex_terminal_provider")
  return ok and provider or nil
end

--- Returns the worktree associated with the active Codex slot.
local function active_worktree()
  local provider = terminal_provider()
  local root = provider and provider.get_active_worktree and provider.get_active_worktree() or nil
  return git_worktree.root(root or vim.fn.getcwd())
end

--- Reports whether a buffer is a repository file inside a worktree.
local function is_worktree_buffer(bufnr, root)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].buftype ~= "" then
    return false
  end
  local path = vim.api.nvim_buf_get_name(bufnr)
  return path ~= "" and git_worktree.contains(root, path)
end

--- Finds the main normal editing window in the current Neovim tab.
local function editor_window()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == "" then
      return win
    end
  end
  return nil
end

--- Records a repository buffer as the latest one viewed in its active worktree.
local function remember_buffer(bufnr)
  local root = active_worktree()
  if root and is_worktree_buffer(bufnr, root) then
    contexts[root] = contexts[root] or {}
    contexts[root].bufnr = bufnr
  end
end

--- Restores the remembered repository buffer or a new empty buffer.
local function restore_buffer(root)
  local win = editor_window()
  if not win then
    return
  end

  local context = contexts[root]
  local bufnr = context and context.bufnr or nil
  if not bufnr or not is_worktree_buffer(bufnr, root) then
    bufnr = vim.api.nvim_create_buf(true, false)
    vim.bo[bufnr].bufhidden = "hide"
  end
  vim.api.nvim_win_set_buf(win, bufnr)
end

--- Records Neo-tree's selected repository location for one worktree.
local function remember_neo_tree(root)
  --- Reads optional Neo-tree state without making context switches depend on the plugin.
  pcall(function()
    local state = require("neo-tree.sources.manager").get_state("filesystem")
    local node = state.tree and state.tree:get_node() or nil
    local path = node and (node.path or node:get_id()) or nil
    if path and git_worktree.contains(root, path) then
      contexts[root] = contexts[root] or {}
      contexts[root].neo_tree_path = git_worktree.normalize(path)
    end
  end)
end

--- Moves Neo-tree to a worktree without changing the user's focused window.
local function move_neo_tree(root)
  local previous_win = vim.api.nvim_get_current_win()
  local previous_mode = vim.fn.mode():sub(1, 1)
  local context = contexts[root]
  local reveal_file = context and context.neo_tree_path or nil
  if reveal_file and vim.fn.filereadable(reveal_file) == 0 and vim.fn.isdirectory(reveal_file) == 0 then
    reveal_file = nil
  end

  --- Opens Neo-tree without making a context switch depend on the plugin.
  pcall(function()
    require("lazy").load({ plugins = { "neo-tree.nvim" } })
    require("neo-tree.command").execute({
      action = "show",
      source = "filesystem",
      position = "right",
      dir = root,
      reveal_file = reveal_file,
    })
  end)

  if vim.api.nvim_win_is_valid(previous_win) then
    vim.api.nvim_set_current_win(previous_win)
    if previous_mode == "t" then
      vim.cmd.startinsert()
    end
  end
end

--- Switches Neovim's browsing context to a worktree.
function M.switch_context(path)
  local root = git_worktree.root(path)
  if not root or vim.fn.isdirectory(root) == 0 then
    return false, "The selected worktree is unavailable"
  end

  local previous_root = git_worktree.root(vim.fn.getcwd())
  if previous_root then
    remember_neo_tree(previous_root)
  end

  local changed, err = pcall(vim.cmd, "cd " .. vim.fn.fnameescape(root))
  if not changed then
    return false, tostring(err)
  end

  restore_buffer(root)
  move_neo_tree(root)
  return true
end

--- Opens or focuses a Codex slot for an existing worktree.
function M.open_worktree(path)
  local root = git_worktree.root(path)
  local provider = terminal_provider()
  if not root or not provider then
    vim.notify("Unable to open the selected worktree", vim.log.levels.ERROR, { title = "Worktrees" })
    return false
  end

  local slot_index = provider.find_recent_slot_for_worktree(root)
  if slot_index then
    return provider.switch_to_slot(slot_index)
  end

  local switched, err = M.switch_context(root)
  if not switched then
    vim.notify(err, vim.log.levels.ERROR, { title = "Worktrees" })
    return false
  end
  return provider.new_slot()
end

--- Opens the Snacks picker for worktrees in the active repository.
function M.pick()
  local root = active_worktree()
  local worktrees, err = git_worktree.list(root)
  if not worktrees then
    vim.notify(err, vim.log.levels.ERROR, { title = "Worktrees" })
    return
  end

  --- Converts one Git worktree into a compact picker item.
  local items = vim.tbl_map(function(worktree)
    return {
      text = worktree.name,
      name = worktree.name,
      path = worktree.path,
      main = worktree.main,
    }
  end, worktrees)

  Snacks.picker.pick({
    source = "worktrees",
    title = "Worktrees",
    --- Returns the worktree items for this picker invocation.
    finder = function()
      return items
    end,
    --- Displays only the worktree directory name.
    format = function(item)
      return { { item.name, "SnacksPickerFile" } }
    end,
    layout = { preset = "left", preview = false },
    --- Opens the worktree represented by the confirmed picker item.
    confirm = function(picker, item)
      picker:close()
      if item then
        --- Waits until the picker has closed before changing context.
        vim.schedule(function()
          M.open_worktree(item.path)
        end)
      end
    end,
  })
end

--- Records a pending conversation handoff sent by the Codex helper.
function M.schedule_handoff(encoded)
  local decoded_ok, decoded = pcall(vim.base64.decode, encoded)
  local payload_ok, payload = false, nil
  if decoded_ok then
    payload_ok, payload = pcall(vim.json.decode, decoded)
  end
  if not payload_ok or type(payload) ~= "table" then
    return "invalid"
  end

  local slot_id = tonumber(payload.slot_id)
  local provider = terminal_provider()
  local slot = provider and slot_id and provider.get_slot_info(slot_id) or nil
  local target = git_worktree.root(payload.new_worktree)
  if not slot or not target or slot.worktree ~= git_worktree.root(payload.old_worktree) then
    return "invalid"
  end

  payload.slot_id = slot_id
  payload.new_worktree = target
  pending_handoffs[slot_id] = payload
  return "scheduled"
end

--- Completes a pending handoff after the current Codex turn stops.
local function complete_handoff(slot_id, session_id)
  local payload = pending_handoffs[slot_id]
  if not payload or (session_id and payload.session_id ~= session_id) then
    return false
  end
  pending_handoffs[slot_id] = nil

  --- Restarts the slot after the Stop hook response has returned.
  vim.schedule(function()
    local provider = terminal_provider()
    if provider then
      provider.resume_slot_in_worktree(slot_id, payload.new_worktree, payload.session_id, payload)
    end
  end)
  return true
end

--- Applies worktree behavior for one encoded Codex lifecycle hook.
function M.handle_hook_payload(encoded)
  local decoded_ok, decoded = pcall(vim.base64.decode, encoded)
  if not decoded_ok then
    return "invalid"
  end
  local parsed, payload = pcall(vim.json.decode, decoded)
  if not parsed or type(payload) ~= "table" then
    return "invalid"
  end
  if payload.hook_event_name == "Stop" then
    complete_handoff(tonumber(payload._handsfree_slot_id), payload.session_id)
  end
  return "ok"
end

--- Installs buffer tracking for worktree browsing contexts.
function M.setup()
  if setup_complete then
    return
  end
  setup_complete = true

  local group = vim.api.nvim_create_augroup("codex_worktree_context", { clear = true })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    --- Remembers repository buffers as they become visible.
    callback = function(event)
      remember_buffer(event.buf)
    end,
  })
  remember_buffer(vim.api.nvim_get_current_buf())
end

--- Resets module state for focused headless tests.
function M._reset_for_test()
  contexts = {}
  pending_handoffs = {}
end

return M
]=]
