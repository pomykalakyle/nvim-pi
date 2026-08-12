-- Reviewed: true.
if vim.g.vscode then
  require("config.colemak").setup({ vscode = true })
else
  require("config.lazy")
end
