-- Adapts CodeDiff's internal computation and rendering modules for Pi previews.

local M = {}

---Load CodeDiff before accessing one of its internal modules.
--- Reviewed: false.
function M.load(module_name)
  local lazy_ok, lazy = pcall(require, "lazy")
  if lazy_ok then
    local loaded, load_error = pcall(lazy.load, { plugins = { "codediff.nvim" } })
    if not loaded then
      return nil, tostring(load_error)
    end
  end

  local ok, module = pcall(require, module_name)
  if not ok then
    return nil, tostring(module)
  end
  return module, nil
end

---Remove the virtual lines and highlights added by CodeDiff.
---The underlying proposed text stays untouched.
--- Reviewed: false.
function M.clear_inline(preview)
  if preview.inline_renderer and vim.api.nvim_buf_is_valid(preview.proposed_buf) then
    pcall(preview.inline_renderer.clear, preview.proposed_buf)
  end
end

---Annotate the proposed buffer with additions, changes, and virtual deleted lines.
--- Reviewed: false.
function M.render_inline(preview)
  local inline, load_error = M.load("codediff.ui.inline")
  if not inline then
    error("failed to load CodeDiff: " .. load_error, 0)
  end

  local original_lines = vim.api.nvim_buf_get_lines(preview.before_buf, 0, -1, false)
  local proposed_lines = vim.api.nvim_buf_get_lines(preview.proposed_buf, 0, -1, false)
  inline.render_inline_diff(
    preview.proposed_buf,
    preview.diff_result,
    original_lines,
    proposed_lines,
    { filetype = vim.bo[preview.proposed_buf].filetype }
  )
  preview.inline_renderer = inline
end

---Remove CodeDiff's side-by-side highlights, filler rows, and scroll binding.
--- Reviewed: false.
function M.clear_side_by_side(preview)
  local lifecycle = M.load("codediff.ui.lifecycle")
  if lifecycle then
    for _, buf in ipairs({ preview.before_buf, preview.proposed_buf }) do
      if buf and vim.api.nvim_buf_is_valid(buf) then
        pcall(lifecycle.clear_highlights, buf)
      end
    end
  end

  local scroll = M.load("codediff.ui.scroll")
  if scroll and preview.before_win and vim.api.nvim_win_is_valid(preview.before_win) then
    pcall(scroll.teardown, vim.api.nvim_win_get_tabpage(preview.before_win))
  end
end

---Render CodeDiff's paired-buffer highlights and virtual filler rows.
--- Reviewed: false.
function M.render_side_by_side(preview)
  local core, core_error = M.load("codediff.ui.core")
  if not core then
    error("failed to load CodeDiff: " .. core_error, 0)
  end

  local original_lines = vim.api.nvim_buf_get_lines(preview.before_buf, 0, -1, false)
  local proposed_lines = vim.api.nvim_buf_get_lines(preview.proposed_buf, 0, -1, false)
  core.render_diff(preview.before_buf, preview.proposed_buf, original_lines, proposed_lines, preview.diff_result)
end

---Bind scrolling after folds change the two panes' visible structure.
--- Reviewed: false.
function M.synchronize_side_by_side(preview)
  local scroll, scroll_error = M.load("codediff.ui.scroll")
  if not scroll then
    error("failed to load CodeDiff: " .. scroll_error, 0)
  end
  local tabpage = vim.api.nvim_win_get_tabpage(preview.proposed_win)
  scroll.bind(tabpage, { preview.before_win, preview.proposed_win })
  scroll.resync(tabpage, preview.proposed_win)
end

return M
