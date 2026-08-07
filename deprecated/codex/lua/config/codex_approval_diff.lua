-- Deprecated Codex-only implementation retained for migration reference.
--[=[
local M = {}

local active_preview = nil
local preferred_layout = vim.g.codex_approval_diff_layout == "unified" and "unified" or "side_by_side"

---Remember the approval diff layout for later previews in this Neovim session.
local function set_preferred_layout(layout)
  preferred_layout = layout
  vim.g.codex_approval_diff_layout = layout
end

---Read and decode a JSON file produced by the apply_patch preview helper.
local function read_json_file(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil, "failed to read " .. tostring(path)
  end

  local raw = table.concat(lines, "\n")
  local decoded_ok, payload = pcall(vim.json.decode, raw)
  if not decoded_ok or type(payload) ~= "table" then
    return nil, "failed to decode " .. tostring(path)
  end

  return payload, nil
end

---Split buffer text into Neovim buffer lines, preserving an empty buffer line for empty text.
local function split_lines(text)
  if type(text) ~= "string" or text == "" then
    return { "" }
  end

  local lines = vim.split(text, "\n", { plain = true })
  if #lines == 0 then
    return { "" }
  end
  return lines
end

---Return a display-safe basename for a real or synthetic preview path.
local function basename(path)
  local name = vim.fn.fnamemodify(path or "", ":t")
  if name == "" then
    return "preview"
  end
  return name
end

---Find the visible non-floating window that contains the active codex.nvim terminal buffer.
local function find_codex_terminal_window()
  local ok, terminal = pcall(require, "codex.terminal")
  if not ok or type(terminal.get_active_terminal_bufnr) ~= "function" then
    return nil
  end

  local terminal_bufnr = terminal.get_active_terminal_bufnr()
  if not terminal_bufnr then
    return nil
  end

  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == terminal_bufnr then
      local config = vim.api.nvim_win_get_config(win)
      if not (config.relative and config.relative ~= "") then
        return win
      end
    end
  end

  return nil
end

---Return focus to the visible Codex terminal after approval preview UI work completes.
local function focus_codex_terminal(fallback_win)
  local terminal_win = find_codex_terminal_window()
  if terminal_win and vim.api.nvim_win_is_valid(terminal_win) then
    vim.api.nvim_set_current_win(terminal_win)
    pcall(vim.cmd, "startinsert")
  elseif fallback_win and vim.api.nvim_win_is_valid(fallback_win) then
    vim.api.nvim_set_current_win(fallback_win)
  end
end

---Return true when a window was created for an approval diff preview.
local function is_approval_diff_window(win)
  local ok, value = pcall(vim.api.nvim_win_get_var, win, "codex_approval_diff")
  return ok and value == true
end

---Return true when a window is managed by edgy.nvim as a sidebar/panel.
local function is_edgy_window(win)
  local ok, edgy = pcall(require, "edgy")
  if not ok or type(edgy.get_win) ~= "function" then
    return false
  end

  local found_ok, edgy_win = pcall(edgy.get_win, win)
  return found_ok and edgy_win ~= nil
end

---Return true when a window can be replaced by the approval diff preview.
local function is_review_target_candidate(win)
  if not vim.api.nvim_win_is_valid(win) then
    return false
  end

  local config = vim.api.nvim_win_get_config(win)
  if config.relative and config.relative ~= "" then
    return false
  end

  if is_approval_diff_window(win) or is_edgy_window(win) then
    return false
  end

  local bufnr = vim.api.nvim_win_get_buf(win)
  return vim.bo[bufnr].buftype == ""
end

---Sort windows by their top-left screen position.
local function compare_window_screenpos(left, right)
  local left_pos = vim.fn.win_screenpos(left)
  local right_pos = vim.fn.win_screenpos(right)
  if left_pos[1] == right_pos[1] then
    return left_pos[2] < right_pos[2]
  end
  return left_pos[1] < right_pos[1]
end

---Find the top-left normal text window that can host the approval diff.
local function find_review_target_window()
  local candidates = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if is_review_target_candidate(win) then
      candidates[#candidates + 1] = win
    end
  end

  table.sort(candidates, compare_window_screenpos)
  return candidates[1]
end

---Find a stable visible window to split from when no normal text window exists.
local function find_split_anchor_window()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_is_valid(win) then
      local config = vim.api.nvim_win_get_config(win)
      if
        not (config.relative and config.relative ~= "")
        and not is_approval_diff_window(win)
        and not is_edgy_window(win)
      then
        return win
      end
    end
  end

  return nil
end

---Create a temporary normal window for approval diffs when the tab has only tool panes.
local function create_review_target_window()
  local original_win = vim.api.nvim_get_current_win()
  local anchor_win = find_split_anchor_window()

  if anchor_win and vim.api.nvim_win_is_valid(anchor_win) then
    vim.api.nvim_set_current_win(anchor_win)
  end

  local ok = pcall(vim.cmd, "topleft new")
  if not ok then
    if vim.api.nvim_win_is_valid(original_win) then
      pcall(vim.api.nvim_set_current_win, original_win)
    end
    return nil, nil
  end

  local win = vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].buflisted = false

  if vim.api.nvim_win_is_valid(original_win) then
    pcall(vim.api.nvim_set_current_win, original_win)
  end

  return win, bufnr
end

---Return an existing target window or create a temporary one for the preview.
local function resolve_review_target_window()
  local target_win = find_review_target_window()
  if target_win then
    return target_win, false, nil
  end

  local fallback_win, fallback_buf = create_review_target_window()
  if not fallback_win then
    return nil, false, nil
  end

  return fallback_win, true, fallback_buf
end

---Find all windows and buffers created by an approval diff preview.
local function collect_existing()
  local diff_windows = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if is_approval_diff_window(win) and vim.api.nvim_win_is_valid(win) then
      diff_windows[#diff_windows + 1] = win
    end
  end

  table.sort(diff_windows, compare_window_screenpos)

  local diff_buffers = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    local ok, value = pcall(vim.api.nvim_buf_get_var, bufnr, "codex_approval_diff")
    if ok and value == true and vim.api.nvim_buf_is_valid(bufnr) then
      diff_buffers[#diff_buffers + 1] = bufnr
    end
  end

  return diff_windows, diff_buffers
end

---Delete scratch buffers from a previous approval diff preview once they are hidden.
local function delete_diff_buffers(buffers)
  for _, bufnr in ipairs(buffers or {}) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end
end

---Turn diff mode off in a window without changing the caller's current window.
local function diffoff(win)
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_call, win, function()
      pcall(vim.cmd, "diffoff")
    end)
  end
end

---Close leftover approval diff windows and buffers without restoring saved text state.
local function close_stray_previews()
  local diff_windows, diff_buffers = collect_existing()

  for _, win in ipairs(diff_windows) do
    diffoff(win)
    pcall(vim.api.nvim_win_close, win, true)
  end

  delete_diff_buffers(diff_buffers)
end

---Create a scratch, read-only buffer containing one side of the approval diff.
local function make_buffer(name, file_path, content)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_var(bufnr, "codex_approval_diff", true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = true
  pcall(vim.api.nvim_buf_set_name, bufnr, name)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, split_lines(content))
  vim.bo[bufnr].modified = false
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly = true

  local ft = vim.filetype.match({ filename = file_path })
  if ft then
    vim.bo[bufnr].filetype = ft
  end

  return bufnr
end

---Install the approval diff layout toggle on one scratch buffer.
local function configure_diff_buffer(bufnr)
  vim.keymap.set("n", "t", M.toggle_layout, {
    buffer = bufnr,
    desc = "Codex: Toggle diff layout",
    nowait = true,
    silent = true,
  })
end

---Load CodeDiff's diff computation and inline rendering modules.
local function load_inline_renderer()
  local lazy_ok, lazy = pcall(require, "lazy")
  if lazy_ok then
    local load_ok, load_err = pcall(lazy.load, { plugins = { "codediff.nvim" } })
    if not load_ok then
      return nil, nil, tostring(load_err)
    end
  end

  local diff_ok, diff_module = pcall(require, "codediff.core.diff")
  if not diff_ok then
    return nil, nil, tostring(diff_module)
  end

  local inline_ok, inline = pcall(require, "codediff.ui.inline")
  if not inline_ok then
    return nil, nil, tostring(inline)
  end

  return diff_module, inline, nil
end

---Clear CodeDiff's inline decorations from the modified preview buffer.
local function clear_inline_preview(preview)
  if preview.inline_renderer then
    preview.inline_renderer.clear(preview.new_buf)
  end
end

---Render a VS Code-style inline diff over the modified preview buffer.
local function render_inline_preview(preview)
  local diff_module, inline, load_err = load_inline_renderer()
  if not diff_module then
    vim.notify("Codex approval diff: failed to load CodeDiff: " .. load_err, vim.log.levels.ERROR)
    return false
  end

  local old_lines = vim.api.nvim_buf_get_lines(preview.old_buf, 0, -1, false)
  local new_lines = vim.api.nvim_buf_get_lines(preview.new_buf, 0, -1, false)
  if not preview.inline_diff_result then
    local compute_ok, result = pcall(diff_module.compute_diff, old_lines, new_lines, {
      max_computation_time_ms = 5000,
      ignore_trim_whitespace = false,
      compute_moves = false,
    })
    if not compute_ok or not result then
      vim.notify("Codex approval diff: CodeDiff failed: " .. tostring(result), vim.log.levels.ERROR)
      return false
    end
    preview.inline_diff_result = result
  end

  local render_ok, render_err = pcall(
    inline.render_inline_diff,
    preview.new_buf,
    preview.inline_diff_result,
    old_lines,
    new_lines,
    { filetype = vim.bo[preview.new_buf].filetype }
  )
  if not render_ok then
    vim.notify("Codex approval diff: CodeDiff render failed: " .. tostring(render_err), vim.log.levels.ERROR)
    return false
  end

  preview.inline_renderer = inline
  return true
end

---Apply window-local options used for approval diff panes.
local function configure_diff_window(win)
  vim.api.nvim_win_set_var(win, "codex_approval_diff", true)
  vim.wo[win].wrap = false
  vim.wo[win].number = true
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "yes"
  vim.wo[win].foldcolumn = "0"
end

---Reveal the real file affected by the approval diff in Neo-tree.
local function reveal_preview_target(path)
  if type(path) ~= "string" or path == "" then
    return
  end

  local reveal_path = vim.fn.fnamemodify(path, ":p")
  if reveal_path == "" then
    return
  end

  if vim.fn.filereadable(reveal_path) == 0 and vim.fn.isdirectory(reveal_path) == 0 then
    local parent = vim.fn.fnamemodify(reveal_path, ":h")
    if parent == "" or vim.fn.isdirectory(parent) == 0 then
      return
    end
    reveal_path = parent
  end

  pcall(function()
    require("neo-tree.command").execute({
      action = "show",
      source = "filesystem",
      position = "right",
      reveal_file = reveal_path,
    })
  end)
end

---Save the current view of a valid approval diff window.
local function save_window_view(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return nil
  end

  return vim.api.nvim_win_call(win, vim.fn.winsaveview)
end

---Restore a saved view in a valid approval diff window.
local function restore_window_view(win, view)
  if win and view and vim.api.nvim_win_is_valid(win) then
    ---Restore the captured view inside its owning window.
    local function restore_view()
      vim.fn.winrestview(view)
    end

    pcall(vim.api.nvim_win_call, win, restore_view)
  end
end

---Enable native side-by-side diff mode for the active preview buffers.
local function show_side_by_side(preview)
  clear_inline_preview(preview)
  vim.api.nvim_set_current_win(preview.old_win)
  vim.api.nvim_win_set_buf(preview.old_win, preview.old_buf)
  configure_diff_window(preview.old_win)

  vim.cmd("rightbelow vsplit")
  preview.new_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(preview.new_win, preview.new_buf)
  configure_diff_window(preview.new_win)

  vim.api.nvim_set_current_win(preview.old_win)
  vim.cmd("diffthis")
  vim.api.nvim_set_current_win(preview.new_win)
  vim.cmd("diffthis")

  restore_window_view(preview.old_win, preview.side_by_side_views and preview.side_by_side_views.old)
  restore_window_view(preview.new_win, preview.side_by_side_views and preview.side_by_side_views.new)
  preview.layout = "side_by_side"
  return true
end

---Replace the native split diff with CodeDiff's inline rendering.
local function show_unified(preview)
  if not render_inline_preview(preview) then
    return false
  end

  preview.side_by_side_views = {
    old = save_window_view(preview.old_win),
    new = save_window_view(preview.new_win),
  }

  diffoff(preview.old_win)
  diffoff(preview.new_win)
  if preview.new_win and vim.api.nvim_win_is_valid(preview.new_win) then
    pcall(vim.api.nvim_win_close, preview.new_win, true)
  end
  preview.new_win = nil

  vim.api.nvim_win_set_buf(preview.old_win, preview.new_buf)
  configure_diff_window(preview.old_win)
  restore_window_view(preview.old_win, preview.unified_view)
  preview.layout = "unified"
  return true
end

---Open a side-by-side full-file diff for a decoded preview payload.
local function open_preview(payload)
  local original_win = vim.api.nvim_get_current_win()
  M.restore_preview()

  local target_win, close_target_on_restore, fallback_buf = resolve_review_target_window()
  if not target_win then
    vim.notify("Codex approval diff: text window not found", vim.log.levels.ERROR)
    return false
  end

  vim.api.nvim_set_current_win(target_win)
  local original_buf = vim.api.nvim_win_get_buf(target_win)
  local original_view = vim.fn.winsaveview()

  local id = payload.tool_use_id or tostring(os.time())
  local old_path = payload.old_path or ""
  local new_path = payload.new_path or old_path
  local old_buf =
    make_buffer(("codex://approval/%s/old/%s"):format(id, basename(old_path)), old_path, payload.old_content or "")
  local new_buf =
    make_buffer(("codex://approval/%s/new/%s"):format(id, basename(new_path)), new_path, payload.new_content or "")

  configure_diff_buffer(old_buf)
  configure_diff_buffer(new_buf)

  vim.api.nvim_set_current_win(target_win)
  local old_win = target_win

  active_preview = {
    target_win = old_win,
    original_buf = original_buf,
    original_view = original_view,
    old_win = old_win,
    new_win = nil,
    old_buf = old_buf,
    new_buf = new_buf,
    tool_use_id = payload.tool_use_id,
    close_target_on_restore = close_target_on_restore,
    fallback_buf = fallback_buf,
    layout = "side_by_side",
  }
  show_side_by_side(active_preview)
  if preferred_layout == "unified" then
    show_unified(active_preview)
  end

  reveal_preview_target(new_path ~= "" and new_path or old_path)

  focus_codex_terminal(original_win)
  vim.schedule(function()
    focus_codex_terminal(original_win)
  end)
  vim.defer_fn(function()
    focus_codex_terminal(original_win)
  end, 100)

  return true
end

---Toggle the active Codex approval preview between side-by-side and unified layouts.
function M.toggle_layout()
  local preview = active_preview
  if not preview or not preview.old_win or not vim.api.nvim_win_is_valid(preview.old_win) then
    vim.notify("Codex approval diff: no active preview", vim.log.levels.WARN)
    return false
  end

  local original_win = vim.api.nvim_get_current_win()
  local toggled
  if preview.layout == "unified" then
    preview.unified_view = save_window_view(preview.old_win)
    toggled = show_side_by_side(preview)
  else
    preview.side_by_side_focus = original_win == preview.new_win and "new" or "old"
    toggled = show_unified(preview)
  end

  if not toggled then
    if vim.api.nvim_win_is_valid(original_win) then
      vim.api.nvim_set_current_win(original_win)
    end
    return false
  end
  set_preferred_layout(preview.layout)

  if
    original_win ~= preview.old_win
    and original_win ~= preview.new_win
    and vim.api.nvim_win_is_valid(original_win)
  then
    vim.api.nvim_set_current_win(original_win)
  elseif preview.layout == "side_by_side" and preview.side_by_side_focus == "new" then
    vim.api.nvim_set_current_win(preview.new_win)
  else
    vim.api.nvim_set_current_win(preview.old_win)
  end

  return true
end

---Restore the text window that was replaced by the active approval diff.
function M.restore_preview()
  vim.schedule(function()
    vim.cmd("checktime")
  end)

  local original_win = vim.api.nvim_get_current_win()
  local preview = active_preview
  active_preview = nil

  if not preview then
    close_stray_previews()
    return true
  end

  diffoff(preview.old_win)
  diffoff(preview.new_win)
  clear_inline_preview(preview)

  if preview.new_win and vim.api.nvim_win_is_valid(preview.new_win) then
    pcall(vim.api.nvim_win_close, preview.new_win, true)
  end

  if preview.close_target_on_restore and preview.target_win and vim.api.nvim_win_is_valid(preview.target_win) then
    pcall(vim.api.nvim_win_close, preview.target_win, true)
  elseif preview.target_win and vim.api.nvim_win_is_valid(preview.target_win) then
    pcall(vim.api.nvim_win_set_var, preview.target_win, "codex_approval_diff", false)
    vim.api.nvim_set_current_win(preview.target_win)

    if preview.original_buf and vim.api.nvim_buf_is_valid(preview.original_buf) then
      vim.api.nvim_win_set_buf(preview.target_win, preview.original_buf)
      if preview.original_view then
        pcall(vim.fn.winrestview, preview.original_view)
      end
    else
      vim.cmd("enew")
    end
  end

  delete_diff_buffers({ preview.old_buf, preview.new_buf })
  if preview.fallback_buf and vim.api.nvim_buf_is_valid(preview.fallback_buf) then
    pcall(vim.api.nvim_buf_delete, preview.fallback_buf, { force = true })
  end
  close_stray_previews()

  if vim.api.nvim_win_is_valid(original_win) then
    pcall(vim.api.nvim_set_current_win, original_win)
  end

  return true
end

---RPC entrypoint used by the hook helper to open an approval diff from a temp JSON file.
function M.open_from_file(path)
  local payload, err = read_json_file(path)
  if not payload then
    vim.notify("Codex approval diff: " .. err, vim.log.levels.ERROR)
    return false
  end

  local ok, opened = pcall(open_preview, payload)
  if not ok then
    vim.notify("Codex approval diff: " .. tostring(opened), vim.log.levels.ERROR)
    return false
  end
  return opened == true
end

vim.api.nvim_create_user_command("CodexDiffToggle", M.toggle_layout, {
  desc = "Toggle the active Codex approval diff layout",
  force = true,
})

return M
]=]
