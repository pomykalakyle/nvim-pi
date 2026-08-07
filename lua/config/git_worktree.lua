-- Provides shared Git worktree path, repository identity, and discovery helpers.

local M = {}

--- Normalizes a filesystem path for worktree comparisons.
function M.normalize(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  local absolute = vim.fn.fnamemodify(vim.fn.expand(path), ":p"):gsub("/$", "")
  return vim.fn.resolve(absolute):gsub("/$", "")
end

--- Runs a Git command and returns its output lines.
local function run_git(path, args)
  local cwd = M.normalize(path)
  if not cwd then
    return nil, "A Git working directory is required"
  end

  local command = { "git", "-C", cwd }
  vim.list_extend(command, args)
  local output = vim.fn.systemlist(command)
  if vim.v.shell_error ~= 0 then
    return nil, table.concat(output, "\n")
  end
  return output
end

--- Returns the worktree root containing a path.
function M.root(path)
  local normalized = M.normalize(path)
  if not normalized then
    return nil
  end

  if vim.fn.filereadable(normalized) == 1 then
    normalized = M.normalize(vim.fn.fnamemodify(normalized, ":h"))
  end

  local output = run_git(normalized, { "rev-parse", "--show-toplevel" })
  return output and M.normalize(output[1]) or nil
end

--- Returns the shared Git directory used as a repository identity.
function M.common_dir(path)
  local root = M.root(path)
  if not root then
    return nil
  end

  local output = run_git(root, { "rev-parse", "--path-format=absolute", "--git-common-dir" })
  return output and M.normalize(output[1]) or root
end

--- Reports whether a path belongs to a worktree root.
function M.contains(root, path)
  root = M.normalize(root)
  path = M.normalize(path)
  return root ~= nil and path ~= nil and (path == root or vim.startswith(path, root .. "/"))
end

--- Lists the worktrees belonging to the repository containing a path.
function M.list(path)
  local root = M.root(path)
  if not root then
    return nil, "The active directory is not inside a Git worktree"
  end

  local lines, err = run_git(root, { "worktree", "list", "--porcelain" })
  if not lines then
    return nil, err
  end

  local worktrees = {}
  local entry = nil

  --- Adds the current porcelain entry to the result.
  local function finish_entry()
    if not entry or not entry.path then
      entry = nil
      return
    end
    entry.name = vim.fn.fnamemodify(entry.path, ":t")
    entry.main = #worktrees == 0
    worktrees[#worktrees + 1] = entry
    entry = nil
  end

  for _, line in ipairs(lines) do
    if line == "" then
      finish_entry()
    else
      local key, value = line:match("^(%S+)%s*(.*)$")
      if key == "worktree" then
        finish_entry()
        entry = { path = M.normalize(value) }
      elseif entry and key == "HEAD" then
        entry.head = value
      elseif entry and key == "branch" then
        entry.branch = value
      elseif entry and key == "detached" then
        entry.detached = true
      end
    end
  end
  finish_entry()

  return worktrees
end

return M
