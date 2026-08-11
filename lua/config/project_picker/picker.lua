-- Keeps project startup and picker actions from opening repositories owned by another Neovim process.

local M = {}
local git_worktree = require("config.git_worktree")
local registry = require("config.project_picker.registry")

local installed = false
local restart_launcher_pid = nil

--- Determines whether this empty-argv launch must choose a project first.
--- Provenance: vibed=true, reviewed=false.
function M.bootstrap()
  if vim.fn.argc() ~= 0 then
    return false
  end

  local git_worktree_root = git_worktree.root(vim.fn.getcwd())
  local root = git_worktree_root and registry.project_key(git_worktree_root) or nil
  local roots = registry.active_roots()
  local launcher_requested_picker = vim.env.NVIM_PI_PICK_PROJECT == "1"
  local needs_picker = launcher_requested_picker or (root and roots[root]) or (not root and next(roots) ~= nil)
  vim.g.user_project_picker_on_startup = needs_picker and true or false
  return vim.g.user_project_picker_on_startup
end

--- Exits normally and asks the parent Bash launcher to open a fresh picker.
--- Provenance: vibed=true, reviewed=false.
function M.restart_to_picker()
  local launcher_pid = tonumber(vim.env.NVIM_PI_LAUNCHER_PID)
  -- Signal zero checks that the launcher exists without notifying or terminating it.
  if not launcher_pid or vim.uv.kill(launcher_pid, 0) ~= 0 then
    vim.notify("The Neovim Pi launcher is unavailable", vim.log.levels.ERROR, { title = "Neovim Project" })
    return false
  end

  -- Delay the signal until Neovim is definitely exiting, so a blocked :qall
  -- cannot leave Bash waiting to perform an unintended restart later.
  restart_launcher_pid = launcher_pid
  local ok, result_or_error = pcall(vim.cmd, "qall")
  if not ok then
    restart_launcher_pid = nil
    vim.notify(tostring(result_or_error), vim.log.levels.ERROR, { title = "Neovim Project" })
    return false
  end
  return true
end

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("user_project_restart", { clear = true }),
  --[[ Provenance: vibed=true, reviewed=false. ]]
  callback = function()
    if restart_launcher_pid then
      local launcher_pid = restart_launcher_pid
      restart_launcher_pid = nil
      vim.uv.kill(launcher_pid, vim.uv.constants.SIGUSR1)
    end
  end,
})

--- Filters picker candidates to roots that are not already open elsewhere.
--- Provenance: vibed=true, reviewed=false.
local function available_projects(history_only)
  local path = require("neovim-project.utils.path")
  local history = require("neovim-project.utils.history")
  local projects

  if history_only then
    projects = history.get_recent_projects()
    projects = path.fix_symlinks_for_history(projects)
    for i = 1, math.floor(#projects / 2) do
      projects[i], projects[#projects - i + 1] = projects[#projects - i + 1], projects[i]
    end
  else
    require("neovim-project.config").options.picker.opts.sorting = "history"
    projects = path.get_all_projects_with_sorting()
  end

  return vim.tbl_filter(--[[ Provenance: vibed=true, reviewed=false. ]] function(project)
    return not registry.root_is_active(git_worktree.root(project))
  end, projects)
end

--- Opens the project picker without already-open roots.
--- Provenance: vibed=true, reviewed=false.
function M.pick_project(history_only)
  local projects = available_projects(history_only)
  if #projects == 0 then
    vim.notify("No unopened projects are available", vim.log.levels.WARN, { title = "Neovim Project" })
    return
  end

  local project = require("neovim-project.project")
  if Snacks then
    local picker_opts = {
      source = "user-projects",
      title = history_only and "Recent Projects" or "Projects",
      items = projects,
      format = "filename",
      --[[ Provenance: vibed=true, reviewed=false. ]]
      transform = function(path)
        return { text = path, file = path, dir = true }
      end,
      --[[ Provenance: vibed=true, reviewed=false. ]]
      confirm = function(picker, item)
        if item then
          local dir = Snacks.picker.util.dir(item)
          picker:close()
          vim.schedule(--[[ Provenance: vibed=true, reviewed=false. ]] function()
            project.switch_project(dir)
          end)
        end
      end,
    }

    if history_only then
      picker_opts.actions = {
        --[[ Provenance: vibed=true, reviewed=false. ]]
        delete_project = function(picker, item)
          local dir = item.file
          local choice = vim.fn.confirm("Delete '" .. dir .. "' from project history?", "&Yes\n&No", 2)
          if choice == 1 then
            project.delete_session(dir)
            require("neovim-project.utils.history").delete_project(dir)
            table.remove(projects, item.idx)
            picker:find()
          end
        end,
      }
      picker_opts.win = {
        input = { keys = { ["<C-d>"] = { "delete_project", mode = { "i", "n" } } } },
        list = { keys = { ["<C-d>"] = { "delete_project", mode = { "i", "n" } } } },
      }
    end

    Snacks.picker.pick(picker_opts)
    return
  end

  vim.ui.select(projects, { prompt = "Projects" }, --[[ Provenance: vibed=true, reviewed=false. ]] function(choice)
    if choice then
      project.switch_project(choice)
    end
  end)
end

--- Prevents plugin commands and picker callbacks from reopening an active root.
--- Provenance: vibed=true, reviewed=false.
function M.install()
  if installed then
    return
  end

  local project = require("neovim-project.project")
  local switch_project = project.switch_project
  project.switch_project = --[[ Provenance: vibed=true, reviewed=false. ]]
    function(dir)
      if registry.root_is_active(git_worktree.root(dir)) then
        vim.notify(
          "That project is already open; choose another project",
          vim.log.levels.WARN,
          { title = "Neovim Project" }
        )
        vim.schedule(--[[ Provenance: vibed=true, reviewed=false. ]] function()
          M.pick_project(false)
        end)
        return
      end

      switch_project(dir)
    end
  installed = true
end

return M
