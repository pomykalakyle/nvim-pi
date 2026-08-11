-- Tracks repositories opened by local Neovim processes using PID-scoped state markers.

local M = {}
local git_worktree = require("config.git_worktree")

-- Keep the existing state path so the split does not change marker compatibility.
local state_dir = vim.fn.stdpath("state") .. "/project-instance-guard"
local marker_path = state_dir .. "/" .. tostring(vim.fn.getpid())
local own_root = nil

--- Normalizes a project root for marker comparisons.
--- Reviewed: false.
local function normalize(root)
  if not root or root == "" then
    return nil
  end

  return vim.fn.fnamemodify(root, ":p"):gsub("/$", "")
end

--- Returns the shared repository identity for a project path.
--- Reviewed: false.
function M.project_key(dir)
  return git_worktree.common_dir(dir) or normalize(dir)
end

--- Reports whether a PID still identifies a live local process.
--- Reviewed: false.
local function pid_is_running(pid)
  return pid and pid ~= vim.fn.getpid() and vim.uv.kill(pid, 0) == 0
end

--- Returns roots currently owned by other live Neovim instances.
--- Reviewed: false.
function M.active_roots()
  vim.fn.mkdir(state_dir, "p")
  local roots = {}

  for _, name in ipairs(vim.fn.readdir(state_dir)) do
    local pid = tonumber(name)
    local path = state_dir .. "/" .. name
    if pid_is_running(pid) then
      local lines = vim.fn.readfile(path)
      local root = M.project_key(lines[1])
      if root then
        roots[root] = true
      end
    else
      pcall(vim.uv.fs_unlink, path)
    end
  end

  return roots
end

--- Reports whether another Neovim instance owns a project root.
--- Reviewed: false.
function M.root_is_active(root)
  root = M.project_key(root)
  return root ~= nil and M.active_roots()[root] == true
end

--- Records this Neovim process as the owner of the current Git repository.
--- Reviewed: false.
function M.activate_current_root()
  local git_worktree_root = git_worktree.root(vim.fn.getcwd())
  local root = git_worktree_root and M.project_key(git_worktree_root) or nil
  if not root or M.root_is_active(root) then
    return
  end

  vim.fn.mkdir(state_dir, "p")
  vim.fn.writefile({ root }, marker_path)
  own_root = root
end

--- Removes this Neovim process from the live-instance registry.
--- Reviewed: false.
function M.deactivate()
  own_root = nil
  pcall(vim.uv.fs_unlink, marker_path)
end

return M
