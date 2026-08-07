-- Loads trusted project-local Neovim configuration as the active project changes.

local M = {}
local git_worktree = require("config.git_worktree")

local active_config

local function config_path_for_current_project()
  local root = git_worktree.root(vim.fn.getcwd())
  if not root then
    return nil
  end

  return vim.fs.joinpath(root, ".nvim.lua")
end

local function notify_error(message)
  vim.notify(message, vim.log.levels.ERROR, { title = "Project config" })
end

function M.unload()
  if not active_config then
    return
  end

  local cleanup = active_config.cleanup
  active_config = nil

  if cleanup then
    local ok, err = pcall(cleanup)
    if not ok then
      notify_error("Could not unload project config: " .. err)
    end
  end
end

function M.load_current()
  local path = config_path_for_current_project()
  if active_config and active_config.path == path then
    return
  end

  M.unload()

  if not path or not vim.uv.fs_stat(path) then
    return
  end

  local contents = vim.secure.read(path)
  if type(contents) ~= "string" then
    return
  end

  local chunk, load_error = load(contents, "@" .. path)
  if not chunk then
    notify_error("Could not load " .. path .. ": " .. load_error)
    return
  end

  local ok, cleanup = pcall(chunk)
  if not ok then
    notify_error("Could not run " .. path .. ": " .. cleanup)
    return
  end

  active_config = {
    path = path,
    cleanup = type(cleanup) == "function" and cleanup or nil,
  }
end

return M
