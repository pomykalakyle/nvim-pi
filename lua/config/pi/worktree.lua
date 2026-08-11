-- Owns Pi worktree selection and per-worktree Neovim browsing contexts.

local M = {}

local editor = require("config.editor")
local git_worktree = require("config.git_worktree")
local tab_root_variable = "pi_worktree_root"
local pending_handoffs = {}

--- Returns the worktree assigned to a native Neovim tabpage.
--- Reviewed: false.
local function tab_worktree(tabpage)
  if not vim.api.nvim_tabpage_is_valid(tabpage) then
    return nil
  end
  local ok, root = pcall(vim.api.nvim_tabpage_get_var, tabpage, tab_root_variable)
  return ok and root or nil
end

--- Returns the worktree containing Neovim's current working directory.
--- Reviewed: false.
local function active_worktree()
  return tab_worktree(vim.api.nvim_get_current_tabpage()) or git_worktree.root(vim.fn.getcwd())
end

--- Returns the worktree assigned to the current native tabpage.
--- Reviewed: false.
function M.active_root()
  return active_worktree()
end

--- Opens Neo-tree at a new worktree tab's root without changing focus.
--- Reviewed: false.
local function open_neo_tree(root)
  editor.with_preserved_focus(--[[ Reviewed: false. ]] function()
    require("lazy").load({ plugins = { "neo-tree.nvim" } })
    require("neo-tree.command").execute({
      action = "show",
      source = "filesystem",
      position = "right",
      dir = root,
    })
  end, true)
end

--- Finds the native Neovim tabpage assigned to a worktree.
--- Reviewed: false.
local function find_worktree_tab(root)
  for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
    if tab_worktree(tabpage) == root then
      return tabpage
    end
  end
  return nil
end

--- Assigns the current native Neovim tabpage to a worktree.
--- Reviewed: false.
local function assign_current_tab(root)
  local tabpage = vim.api.nvim_get_current_tabpage()
  vim.api.nvim_tabpage_set_var(tabpage, tab_root_variable, root)
  vim.cmd("tcd " .. vim.fn.fnameescape(root))
  return tabpage
end

--- Captures the normal editor windows from one tab layout.
--- Reviewed: false.
local function capture_editor_layout(node)
  if node[1] == "leaf" then
    local win = node[2]
    if not editor.is_normal_window(win) then
      return nil
    end
    return {
      kind = "leaf",
      buffer = vim.api.nvim_win_get_buf(win),
      view = vim.api.nvim_win_call(win, vim.fn.winsaveview),
      width = vim.api.nvim_win_get_width(win),
      height = vim.api.nvim_win_get_height(win),
    }
  end

  local children = {}
  for _, child in ipairs(node[2]) do
    local captured = capture_editor_layout(child)
    if captured then
      table.insert(children, captured)
    end
  end
  if #children == 0 then
    return nil
  end
  if #children == 1 then
    return children[1]
  end
  return { kind = node[1], children = children }
end

--- Recreates a captured split tree inside one target window.
--- Reviewed: false.
local function restore_editor_layout(node, target_win)
  if node.kind == "leaf" then
    vim.api.nvim_win_set_buf(target_win, node.buffer)
    vim.api.nvim_win_call(target_win, --[[ Reviewed: false. ]] function()
      vim.fn.winrestview(node.view)
    end)
    pcall(vim.api.nvim_win_set_width, target_win, node.width)
    pcall(vim.api.nvim_win_set_height, target_win, node.height)
    return
  end

  local roots = { target_win }
  for index = 2, #node.children do
    vim.api.nvim_set_current_win(roots[index - 1])
    vim.cmd(node.kind == "row" and "rightbelow vsplit" or "rightbelow split")
    roots[index] = vim.api.nvim_get_current_win()
  end
  for index, child in ipairs(node.children) do
    restore_editor_layout(child, roots[index])
  end
end

--- Creates a native Neovim tabpage for a worktree.
--- Reviewed: false.
local function create_worktree_tab(root)
  vim.cmd.tabnew()
  local tabpage = assign_current_tab(root)
  open_neo_tree(root)
  return tabpage
end

--- Copies the current editor layout into a workspace tab for the same worktree.
--- Reviewed: false.
function M.clone_current_tab(root)
  root = git_worktree.root(root or active_worktree())
  if not root then
    return nil, "The active worktree is unavailable"
  end

  local layout = capture_editor_layout(vim.fn.winlayout())
  vim.cmd.tabnew()
  local tabpage = assign_current_tab(root)
  if layout then
    restore_editor_layout(layout, vim.api.nvim_get_current_win())
  end
  open_neo_tree(root)
  return tabpage
end

--- Selects or creates the native Neovim tabpage for a worktree.
--- Reviewed: false.
function M.switch_context(path)
  M.setup()
  local root = git_worktree.root(path)
  if not root or vim.fn.isdirectory(root) == 0 then
    return false, "The selected worktree is unavailable"
  end

  local tabpage = find_worktree_tab(root)
  if tabpage then
    vim.api.nvim_set_current_tabpage(tabpage)
    return true
  end

  local current_tab = vim.api.nvim_get_current_tabpage()
  if not tab_worktree(current_tab) and git_worktree.root(vim.fn.getcwd()) == root then
    assign_current_tab(root)
    return true
  end

  local created, err = pcall(create_worktree_tab, root)
  if not created then
    return false, tostring(err)
  end
  return true
end

--- Opens the Pi terminal and browsing context for an existing worktree.
--- Reviewed: false.
function M.open_worktree(path)
  local root = git_worktree.root(path)
  if not root then
    vim.notify("Unable to open the selected worktree", vim.log.levels.ERROR, { title = "Worktrees" })
    return false
  end

  local switched, err = M.switch_context(root)
  if not switched then
    vim.notify(err, vim.log.levels.ERROR, { title = "Worktrees" })
    return false
  end

  require("lazy").load({ plugins = { "snacks.nvim" } })
  require("config.pi.workspace").open(root)
  return true
end

--- Acknowledges that a handed-off Pi session finished starting.
--- Reviewed: false.
function M.acknowledge_handoff(token)
  if type(token) ~= "string" or pending_handoffs[token] == nil then
    return false
  end
  pending_handoffs[token] = true
  return true
end

--- Opens a fork of an existing Pi session in a worktree context.
--- Reviewed: false.
function M.handoff(payload)
  if type(payload) ~= "table" or type(payload.session_file) ~= "string" then
    return { ok = false, error = "A Pi session file is required" }
  end
  if vim.fn.filereadable(payload.session_file) == 0 then
    return { ok = false, error = "The Pi session file is unavailable" }
  end

  local root = git_worktree.root(payload.worktree)
  if not root then
    return { ok = false, error = "The selected worktree is unavailable" }
  end

  local previous_tab = vim.api.nvim_get_current_tabpage()
  local created, target_tab = pcall(create_worktree_tab, root)
  if not created then
    local failed_tab = vim.api.nvim_get_current_tabpage()
    if vim.api.nvim_tabpage_is_valid(previous_tab) then
      vim.api.nvim_set_current_tabpage(previous_tab)
    end
    if failed_tab ~= previous_tab and vim.api.nvim_tabpage_is_valid(failed_tab) then
      vim.cmd("tabclose " .. vim.api.nvim_tabpage_get_number(failed_tab))
    end
    return { ok = false, error = tostring(target_tab) }
  end
  local token = vim.fn.sha256(payload.session_file .. tostring(vim.uv.hrtime()))
  pending_handoffs[token] = false
  local opened, terminal = pcall(require("config.pi.workspace").open, root, { "--session", payload.session_file }, {
    PI_NVIM_HANDOFF_ID = token,
  })
  local open_err = terminal
  if opened and not terminal then
    opened = false
    open_err = "Pi failed to open the worktree session"
  elseif opened then
    vim.wait(vim.g.pi_worktree_handoff_timeout_ms or 15000, --[[ Reviewed: false. ]] function()
      if pending_handoffs[token] then
        return true
      end
      local job_id = terminal.buf and vim.b[terminal.buf].terminal_job_id or nil
      return job_id and vim.fn.jobwait({ job_id }, 0)[1] ~= -1 or false
    end, 10)
    opened = pending_handoffs[token] == true
    if not opened then
      require("config.pi.workspace").stop()
      open_err = "Pi did not acknowledge the worktree session startup"
    end
  end
  pending_handoffs[token] = nil

  if not opened then
    if vim.api.nvim_tabpage_is_valid(previous_tab) then
      vim.api.nvim_set_current_tabpage(previous_tab)
    end
    if vim.api.nvim_tabpage_is_valid(target_tab) then
      vim.cmd("tabclose " .. vim.api.nvim_tabpage_get_number(target_tab))
    end
    return { ok = false, error = tostring(open_err) }
  end

  return { ok = true, worktree = root }
end

--- Opens the Snacks picker for worktrees in the active repository.
--- Reviewed: false.
function M.pick()
  M.setup()

  local worktrees, err = git_worktree.list(active_worktree())
  if not worktrees then
    vim.notify(err, vim.log.levels.ERROR, { title = "Worktrees" })
    return
  end

  local workspace = require("config.pi.workspace")
  local workspaces = workspace.list()
  local roots_with_workspaces = {}
  local items = vim.tbl_map(--[[ Reviewed: false. ]] function(item)
    roots_with_workspaces[item.root] = true
    return {
      text = item.title,
      name = item.title,
      kind = "workspace",
      workspace = item.index,
      path = item.root,
    }
  end, workspaces)
  for _, worktree in ipairs(worktrees) do
    if not roots_with_workspaces[worktree.path] then
      table.insert(items, {
        text = worktree.name,
        name = worktree.name .. " [new workspace]",
        kind = "worktree",
        path = worktree.path,
        main = worktree.main,
      })
    end
  end

  Snacks.picker.pick({
    source = "workspaces",
    title = "Workspaces",
    --[[ Reviewed: false. ]]
    finder = function()
      return items
    end,
    --[[ Reviewed: false. ]]
    format = function(item)
      return { { item.name, "SnacksPickerFile" } }
    end,
    layout = { preset = "left", preview = false },
    --[[ Reviewed: false. ]]
    confirm = function(picker, item)
      picker:close()
      if item then
        vim.schedule(--[[ Reviewed: false. ]] function()
          if item.kind == "workspace" then
            workspace.switch(item.workspace)
          else
            M.open_worktree(item.path)
          end
        end)
      end
    end,
  })
end

--- Associates the initial native Neovim tabpage with its worktree.
--- Reviewed: false.
function M.setup()
  local root = git_worktree.root(vim.fn.getcwd())
  if root and tab_worktree(vim.api.nvim_get_current_tabpage()) ~= root then
    assign_current_tab(root)
  end
end

return M
