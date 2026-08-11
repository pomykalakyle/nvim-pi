-- Owns Pi workspaces, their native tabs, browsing context, and terminal processes.

local M = {}

local workspaces = {}
local active_workspace = nil
local next_workspace_id = 1

---Normalizes the project root assigned to a workspace.
--- Reviewed: false.
local function normalize_root(cwd)
  local root = cwd or require("config.pi.worktree").active_root() or vim.fn.getcwd()
  return vim.fn.resolve(vim.fn.fnamemodify(root, ":p")):gsub("/$", "")
end

---Allocates an identity that remains stable for the workspace's lifetime.
--- Reviewed: false.
local function allocate_id()
  local id = next_workspace_id
  next_workspace_id = next_workspace_id + 1
  return id
end

---Reports whether a workspace still has both required Neovim resources.
--- Reviewed: false.
local function workspace_is_valid(workspace)
  return workspace.terminal:buf_valid() and vim.api.nvim_tabpage_is_valid(workspace.tabpage)
end

---Closes workspace-specific preview state without loading the preview module unnecessarily.
--- Reviewed: false.
local function close_workspace_preview(workspace)
  local preview = package.loaded["config.pi.diff_preview"]
  if preview and type(preview.close_workspace) == "function" then
    pcall(preview.close_workspace, workspace.id)
  end
end

---Removes unreachable workspaces and stops terminals left without tabs.
--- Reviewed: false.
local function valid_workspaces()
  local removed_active = false
  for index = #workspaces, 1, -1 do
    local workspace = workspaces[index]
    if not workspace_is_valid(workspace) then
      removed_active = removed_active or active_workspace == workspace
      close_workspace_preview(workspace)
      if workspace.terminal:buf_valid() then
        workspace.terminal:close()
      end
      table.remove(workspaces, index)
    end
  end

  if removed_active then
    active_workspace = nil
    local current_tab = vim.api.nvim_get_current_tabpage()
    for _, workspace in ipairs(workspaces) do
      if workspace.tabpage == current_tab then
        active_workspace = workspace
        break
      end
    end
    active_workspace = active_workspace or workspaces[#workspaces]
  end
  return workspaces
end

---Adds a workspace with an already allocated identity to the registry.
--- Reviewed: false.
local function insert_workspace(id, root, tabpage, terminal)
  local workspace = {
    id = id,
    root = root,
    tabpage = tabpage,
    terminal = terminal,
  }
  workspaces[#workspaces + 1] = workspace
  active_workspace = workspace
  vim.b[terminal.buf].pi_workspace_id = id
  return workspace
end

---Formats the workspace list from the perspective of one Pi terminal.
--- Reviewed: false.
local function workspace_header(active_buf)
  local parts = {}
  for index, workspace in ipairs(valid_workspaces()) do
    local worktree = vim.fn.fnamemodify(workspace.root, ":t")
    local label = ("%d %s"):format(index, worktree)
    parts[index] = workspace.terminal.buf == active_buf and ("[" .. label .. "]") or label
  end
  return #parts > 0 and ("Pi  " .. table.concat(parts, " | ")) or "Pi"
end

---Updates every Pi terminal title after workspace ordering changes.
--- Reviewed: false.
local function update_titles()
  valid_workspaces()
  for _, workspace in ipairs(workspaces) do
    vim.b[workspace.terminal.buf].pi_terminal_title = workspace_header(workspace.terminal.buf)
  end
end

---Shows and focuses the Pi terminal belonging to a workspace.
--- Reviewed: false.
local function focus_workspace(workspace)
  if not workspace.terminal:win_valid() then
    workspace.terminal:show()
  end
  require("config.pi.terminal").focus_instance(workspace.terminal)
  active_workspace = workspace
  return workspace.terminal
end

---Starts a Pi terminal and registers it against the current native tab.
--- Reviewed: false.
local function create_in_current_tab(root, arguments, env)
  local tabpage = vim.api.nvim_get_current_tabpage()
  if M.for_tab(tabpage) then
    error("A Pi workspace already exists in this tab")
  end

  local id = allocate_id()
  local terminal = require("config.pi.terminal").spawn(root, arguments, env, id)
  if not terminal then
    return nil
  end

  insert_workspace(id, root, tabpage, terminal)
  update_titles()
  return focus_workspace(active_workspace)
end

---Returns the workspace and navigation index assigned to a native tab.
--- Reviewed: false.
function M.for_tab(tabpage)
  for index, workspace in ipairs(valid_workspaces()) do
    if workspace.tabpage == tabpage then
      return workspace, index
    end
  end
end

---Returns the workspace with a stable Neovim-local identity.
--- Reviewed: false.
function M.for_id(id)
  for _, workspace in ipairs(valid_workspaces()) do
    if workspace.id == id then
      return workspace
    end
  end
end

---Returns the workspace whose Pi terminal is running the requesting process.
--- Reviewed: false.
function M.for_process(pid)
  for _, workspace in ipairs(valid_workspaces()) do
    if vim.b[workspace.terminal.buf].terminal_job_pid == pid then
      return workspace
    end
  end
end

---Returns the workspace attached to the current native tab.
--- Reviewed: false.
function M.current()
  return M.for_tab(vim.api.nvim_get_current_tabpage())
end

---Returns the most recently active reachable Pi workspace.
--- Reviewed: false.
function M.active()
  valid_workspaces()
  return active_workspace
end

---Creates a copied-layout workspace in the requested project root.
--- Reviewed: false.
function M.create(cwd, arguments, env)
  local root = normalize_root(cwd)
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

---Opens Pi in the current browsing workspace or creates one in this tab.
--- Reviewed: false.
function M.open(cwd, arguments, env)
  local root = normalize_root(cwd)
  local workspace = M.current()
  if workspace then
    if arguments then
      error("A Pi workspace already exists in this tab")
    end
    return focus_workspace(workspace)
  end
  return create_in_current_tab(root, arguments, env)
end

---Switches to one workspace from the unified navigation order.
--- Reviewed: false.
function M.switch(index)
  local workspace = valid_workspaces()[index]
  if not workspace then
    vim.notify("No Pi workspace in slot " .. tostring(index), vim.log.levels.WARN)
    return false
  end
  vim.api.nvim_set_current_tabpage(workspace.tabpage)
  focus_workspace(workspace)
  return true
end

---Selects the next or previous workspace with wraparound.
--- Reviewed: false.
function M.cycle(direction)
  local _, current = M.for_tab(vim.api.nvim_get_current_tabpage())
  local total = #valid_workspaces()
  if total == 0 then
    return false
  end
  if not current then
    return M.switch(direction < 0 and total or 1)
  end
  return M.switch(((current - 1 + direction) % total) + 1)
end

---Focuses the current tab's workspace or the most recently used one.
--- Reviewed: false.
function M.focus_existing()
  local workspace = M.current() or M.active()
  if not workspace then
    return false
  end
  if workspace.tabpage ~= vim.api.nvim_get_current_tabpage() then
    vim.api.nvim_set_current_tabpage(workspace.tabpage)
  end
  focus_workspace(workspace)
  return true
end

---Toggles the Pi terminal owned by the current workspace.
--- Reviewed: false.
function M.toggle()
  local workspace = M.current()
  if not workspace then
    return M.open()
  end
  active_workspace = workspace
  workspace.terminal:toggle()
  require("config.pi.terminal").focus_instance(workspace.terminal)
  return workspace.terminal
end

---Shows and focuses Pi in the current workspace.
--- Reviewed: false.
function M.focus()
  return M.open()
end

---Stops the current workspace, closes its tab, and selects its neighbor.
--- Reviewed: false.
function M.stop()
  local workspace, index = M.for_tab(vim.api.nvim_get_current_tabpage())
  if not workspace then
    return false
  end

  close_workspace_preview(workspace)
  workspace.terminal:close()
  table.remove(workspaces, index)
  local replacement = workspaces[math.min(index, #workspaces)] or workspaces[index - 1]
  if #vim.api.nvim_list_tabpages() > 1 and vim.api.nvim_tabpage_is_valid(workspace.tabpage) then
    vim.cmd("tabclose " .. vim.api.nvim_tabpage_get_number(workspace.tabpage))
  end
  update_titles()
  if replacement and vim.api.nvim_tabpage_is_valid(replacement.tabpage) then
    vim.api.nvim_set_current_tabpage(replacement.tabpage)
    focus_workspace(replacement)
  elseif active_workspace == workspace then
    active_workspace = nil
  end
  return true
end

---Reports whether the current workspace's Pi terminal is visible.
--- Reviewed: false.
function M.is_visible()
  local workspace = M.current()
  return workspace ~= nil and workspace.terminal:win_valid()
end

---Returns workspace metadata for unified navigation and project pickers.
--- Reviewed: false.
function M.list()
  update_titles()
  local items = {}
  for index, workspace in ipairs(workspaces) do
    items[index] = {
      id = workspace.id,
      index = index,
      root = workspace.root,
      tabpage = workspace.tabpage,
      title = vim.b[workspace.terminal.buf].pi_terminal_title,
    }
  end
  return items
end

---Returns the workspace header for a Pi window rendered by Snacks or Edgy.
--- Reviewed: false.
function M.title(win)
  win = win or vim.g.statusline_winid or vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(win) then
    return "Pi"
  end
  return workspace_header(vim.api.nvim_win_get_buf(win))
end

local lifecycle_group = vim.api.nvim_create_augroup("PiWorkspaces", { clear = true })

-- Remove workspaces whose native tabs were closed outside the workspace controls.
vim.api.nvim_create_autocmd("TabClosed", {
  group = lifecycle_group,
  --[[ Reviewed: false. ]]
  callback = function()
    vim.schedule(update_titles)
  end,
})

-- Keep global focus fallback aligned with native tab navigation.
vim.api.nvim_create_autocmd("TabEnter", {
  group = lifecycle_group,
  --[[ Reviewed: false. ]]
  callback = function()
    local workspace = M.current()
    if workspace then
      active_workspace = workspace
    end
  end,
})

return M
