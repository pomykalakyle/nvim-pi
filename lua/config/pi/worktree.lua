-- Owns Pi worktree selection and per-worktree Neovim browsing contexts.

local M = {}

local editor = require("config.editor")
local git_worktree = require("config.git_worktree")
local tab_root_variable = "pi_worktree_root"

--- Returns the worktree assigned to a native Neovim tabpage.
local function tab_worktree(tabpage)
  if not vim.api.nvim_tabpage_is_valid(tabpage) then
    return nil
  end
  local ok, root = pcall(vim.api.nvim_tabpage_get_var, tabpage, tab_root_variable)
  return ok and root or nil
end

--- Returns the worktree containing Neovim's current working directory.
local function active_worktree()
  return tab_worktree(vim.api.nvim_get_current_tabpage()) or git_worktree.root(vim.fn.getcwd())
end

--- Opens Neo-tree at a new worktree tab's root without changing focus.
local function open_neo_tree(root)
  editor.with_preserved_focus(function()
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
local function find_worktree_tab(root)
  for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
    if tab_worktree(tabpage) == root then
      return tabpage
    end
  end
  return nil
end

--- Assigns the current native Neovim tabpage to a worktree.
local function assign_current_tab(root)
  local tabpage = vim.api.nvim_get_current_tabpage()
  vim.api.nvim_tabpage_set_var(tabpage, tab_root_variable, root)
  vim.cmd("tcd " .. vim.fn.fnameescape(root))
  return tabpage
end

--- Creates a native Neovim tabpage for a worktree.
local function create_worktree_tab(root)
  vim.cmd.tabnew()
  local tabpage = assign_current_tab(root)
  open_neo_tree(root)
  return tabpage
end

--- Selects or creates the native Neovim tabpage for a worktree.
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
  require("config.pi.terminal").open(root)
  return true
end

--- Opens the Snacks picker for worktrees in the active repository.
function M.pick()
  M.setup()

  local worktrees, err = git_worktree.list(active_worktree())
  if not worktrees then
    vim.notify(err, vim.log.levels.ERROR, { title = "Worktrees" })
    return
  end

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
    finder = function()
      return items
    end,
    format = function(item)
      return { { item.name, "SnacksPickerFile" } }
    end,
    layout = { preset = "left", preview = false },
    confirm = function(picker, item)
      picker:close()
      if item then
        vim.schedule(function()
          M.open_worktree(item.path)
        end)
      end
    end,
  })
end

--- Associates the initial native Neovim tabpage with its worktree.
function M.setup()
  local root = git_worktree.root(vim.fn.getcwd())
  if root and tab_worktree(vim.api.nvim_get_current_tabpage()) ~= root then
    assign_current_tab(root)
  end
end

return M
