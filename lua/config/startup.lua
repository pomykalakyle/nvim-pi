-- Registers pre-VeryLazy startup behavior for project ownership, session restoration, Pi, and Neo-tree.

local group = vim.api.nvim_create_augroup("user_startup", { clear = true })
local editor = require("config.editor")
local open_project_registry = require("config.project_picker.registry")
local project_local_config = require("config.project_local_config")
local project_picker = require("config.project_picker.picker")
project_picker.bootstrap()

--- Re-detects filetypes for restored normal buffers missing one.
--- Provenance: vibed=true, reviewed=false.
local function restore_empty_filetypes()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" and vim.bo[buf].filetype == "" then
      local name = vim.api.nvim_buf_get_name(buf)
      local ok, filetype = pcall(vim.filetype.match, { buf = buf, filename = name })
      if ok and filetype and filetype ~= "" then
        vim.bo[buf].filetype = filetype
      end
    end
  end
end

--- Opens the interactive Pi terminal after a project session finishes loading.
--- Provenance: vibed=true, reviewed=false.
local function open_pi_for_project()
  require("lazy").load({ plugins = { "snacks.nvim" } })
  require("config.pi.workspace").open()
end

--- Opens Neo-tree after Pi and restores focus to the Pi terminal.
--- Provenance: vibed=true, reviewed=false.
local function open_neo_tree_for_project()
  editor.with_preserved_focus(--[[ Provenance: vibed=true, reviewed=false. ]] function()
    require("lazy").load({ plugins = { "neo-tree.nvim" } })
    require("neo-tree.command").execute({
      action = "focus",
      dir = LazyVim.root(),
    })
  end)
end

--- Records the new project root after the working directory changes.
--- Provenance: vibed=true, reviewed=false.
local function handle_directory_changed()
  open_project_registry.activate_current_root()
  vim.schedule(project_local_config.load_current)
end

--- Restores project UI after a saved session finishes loading.
vim.api.nvim_create_autocmd("User", {
  group = group,
  pattern = "SessionLoadPost",
  --[[ Provenance: vibed=true, reviewed=false. ]]
  callback = function()
    vim.schedule(--[[ Provenance: vibed=true, reviewed=false. ]] function()
      restore_empty_filetypes()
      vim.cmd("silent! filetype detect")
      open_pi_for_project()
      -- Session restoration briefly churns buffers, which can race Neo-tree's
      -- debounced file-follow callback if the tree opens immediately.
      vim.defer_fn(open_neo_tree_for_project, 100)
    end)
  end,
})

vim.api.nvim_create_autocmd("DirChanged", {
  group = group,
  --- Records project ownership after the working directory changes.
  callback = handle_directory_changed,
})

vim.api.nvim_create_autocmd("VimEnter", {
  group = group,
  nested = true,
  --- Starts the session-restore flow for plain empty-argv launches.
  --[[ Provenance: vibed=true, reviewed=false. ]]
  callback = function()
    if vim.fn.argc() == 0 and not vim.g.started_with_stdin then
      if vim.g.user_project_picker_on_startup then
        vim.schedule(--[[ Provenance: vibed=true, reviewed=false. ]] function()
          project_picker.pick_project(false)
        end)
        return
      end

      open_project_registry.activate_current_root()
    end

    project_local_config.load_current()
  end,
})
