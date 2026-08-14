-- Resolves file paths used by Pi tools and editor buffers.

local M = {}

---Resolve a file path consistently across direct and symlinked buffer names.
--- Reviewed: false.
function M.canonical(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end

  local absolute = vim.fn.fnamemodify(path, ":p")
  return vim.uv.fs_realpath(absolute) or vim.fs.normalize(absolute)
end

return M
