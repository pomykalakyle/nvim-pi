-- Restores project UI and trusted local configuration around session changes.

local group = vim.api.nvim_create_augroup("user_startup", { clear = true })
local project_local_config = require("config.project_local_config")
local session_loaded = false

--- Restores filetypes after session loading.
--- Reviewed: true.
local function restore_filetypes()
  -- Session loading can restore multiple file buffers, including hidden ones.
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    -- Leave unloaded, special, and already-detected buffers alone.
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" and vim.bo[buf].filetype == "" then
      local name = vim.api.nvim_buf_get_name(buf)
      local ok, filetype = pcall(vim.filetype.match, { buf = buf, filename = name })
      if ok and filetype and filetype ~= "" then
        vim.bo[buf].filetype = filetype
      end
    end
  end

  -- Run the complete autocmd-based detection path for the current buffer.
  vim.cmd("silent! filetype detect")
end

--- Restores the project UI after session loading has settled.
--- Reviewed: false.
local function restore_project_ui()
  restore_filetypes()
  require("config.pi.workspace").open()
end

--- Loads trusted project-local configuration after the working directory changes.
--- Reviewed: false.
local function handle_directory_changed()
  vim.schedule(project_local_config.load_current)
end

--- Restores project UI after a saved session finishes loading.
vim.api.nvim_create_autocmd("User", {
  group = group,
  pattern = "SessionLoadPost",
  --[[ Reviewed: false. ]]
  callback = function()
    session_loaded = true
    vim.schedule(restore_project_ui)
  end,
})

vim.api.nvim_create_autocmd("DirChanged", {
  group = group,
  callback = handle_directory_changed,
})

vim.api.nvim_create_autocmd("VimEnter", {
  group = group,
  --- Initializes a new Projects session when there was no saved session to load.
  --[[ Reviewed: false. ]]
  callback = function()
    vim.schedule(--[[ Reviewed: false. ]] function()
      project_local_config.load_current()
      if not session_loaded then
        restore_project_ui()
      end
    end)
  end,
})
