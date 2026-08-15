-- Validates Pi proposals and maps their visible ranges across both file versions.

local M = {}

local codediff = require("config.pi.diff_preview.codediff")

---Return whether a decoded RPC argument has every required proposal field.
---Reject malformed values before they can affect the editor layout.
--- Reviewed: false.
function M.is_valid(payload)
  if type(payload) ~= "table" then
    return false
  end
  if type(payload.requester_pid) ~= "number" then
    return false
  end
  for _, key in ipairs({ "tool_call_id", "file_path", "old_content", "new_content" }) do
    if type(payload[key]) ~= "string" then
      return false
    end
  end
  if type(payload.unfolded_ranges) ~= "table" or #payload.unfolded_ranges == 0 then
    return false
  end
  for _, range in ipairs(payload.unfolded_ranges) do
    if
      type(range) ~= "table"
      or type(range.start_line) ~= "number"
      or range.start_line % 1 ~= 0
      or range.start_line < 1
      or type(range.end_line) ~= "number"
      or range.end_line % 1 ~= 0
      or range.end_line < range.start_line
    then
      return false
    end
  end
  return true
end

---Split text into lines accepted by nvim_buf_set_lines().
---Represent empty text as the single empty line required by a buffer.
--- Reviewed: false.
function M.split_lines(text)
  if text == "" then
    return { "" }
  end

  local lines = vim.split(text, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  return #lines > 0 and lines or { "" }
end

---Sort proposed-file ranges and combine overlaps or gaps too small to fold.
--- Reviewed: false.
local function normalize_ranges(ranges, line_count)
  local sorted = vim.deepcopy(ranges)
  table.sort(sorted, --[[ Reviewed: false. ]] function(left, right)
    return left.start_line < right.start_line
      or (left.start_line == right.start_line and left.end_line < right.end_line)
  end)

  local normalized = {}
  for index, range in ipairs(sorted) do
    if range.end_line > line_count then
      return nil,
        ("unfolded_ranges[%d] ends at proposed line %d, but the proposed file has %d lines"):format(
          index,
          range.end_line,
          line_count
        )
    end

    local current = normalized[#normalized]
    -- A one-line fold occupies one row and Neovim will not create it, so show
    -- that line by merging ranges separated by a single line.
    if current and range.start_line <= current.end_line + 2 then
      current.end_line = math.max(current.end_line, range.end_line)
    else
      normalized[#normalized + 1] = {
        start_line = range.start_line,
        end_line = range.end_line,
      }
    end
  end

  if normalized[1] and normalized[1].start_line == 2 then
    normalized[1].start_line = 1
  end
  local last = normalized[#normalized]
  if last and last.end_line == line_count - 1 then
    last.end_line = line_count
  end
  return normalized
end

---Return whether one normalized range fully contains the requested lines.
--- Reviewed: false.
local function range_contains(ranges, start_line, end_line)
  for _, range in ipairs(ranges) do
    if range.start_line <= start_line and range.end_line >= end_line then
      return true
    end
  end
  return false
end

---Convert a line-visibility lookup table into normalized ranges.
--- Reviewed: false.
local function flags_to_ranges(flags, line_count)
  local ranges = {}
  local start_line = nil
  for line = 1, line_count + 1 do
    if line <= line_count and flags[line] then
      start_line = start_line or line
    elseif start_line then
      ranges[#ranges + 1] = { start_line = start_line, end_line = line - 1 }
      start_line = nil
    end
  end
  return normalize_ranges(ranges, line_count)
end

---Validate that the requested proposed-file ranges expose every computed hunk.
---Also map visible unchanged and changed lines onto the original buffer.
--- Reviewed: false.
function M.build_visible_ranges(payload)
  local original_lines = M.split_lines(payload.old_content)
  local proposed_lines = M.split_lines(payload.new_content)
  local proposed_ranges, range_error = normalize_ranges(payload.unfolded_ranges, #proposed_lines)
  if not proposed_ranges then
    return nil, { reason = "preview_range_out_of_bounds", message = range_error }
  end

  local diff_module, load_error = codediff.load("codediff.core.diff")
  if not diff_module then
    return nil,
      {
        reason = "preview_render_failed",
        message = "failed to load CodeDiff: " .. load_error,
      }
  end
  local diff_result = diff_module.compute_diff(original_lines, proposed_lines, {
    max_computation_time_ms = 5000,
    ignore_trim_whitespace = false,
    compute_moves = false,
  })
  if not diff_result then
    return nil,
      {
        reason = "preview_render_failed",
        message = "CodeDiff failed to compute the preview",
      }
  end
  if diff_result.hit_timeout == true then
    return nil,
      {
        reason = "preview_render_failed",
        message = "CodeDiff timed out before it could compute the complete preview",
      }
  end

  local original_visible = {}
  local proposed_visible = {}
  for _, range in ipairs(proposed_ranges) do
    for line = range.start_line, range.end_line do
      proposed_visible[line] = true
    end
  end

  local original_cursor = 1
  local proposed_cursor = 1
  for _, change in ipairs(diff_result.changes or {}) do
    local original_boundary = change.original.start_line
    local original_count = change.original.end_line - original_boundary
    local proposed_boundary = change.modified.start_line
    local proposed_count = change.modified.end_line - proposed_boundary

    while original_cursor < original_boundary and proposed_cursor < proposed_boundary do
      if proposed_visible[proposed_cursor] then
        original_visible[original_cursor] = true
      end
      original_cursor = original_cursor + 1
      proposed_cursor = proposed_cursor + 1
    end

    local visible_start
    local visible_end
    if proposed_count > 0 then
      visible_start = proposed_boundary
      visible_end = proposed_boundary + proposed_count - 1
    else
      -- CodeDiff anchors a pure deletion above the following proposed line.
      -- A deletion at EOF is anchored to the final remaining display line.
      visible_start = math.max(1, math.min(#proposed_lines, proposed_boundary))
      visible_end = visible_start
    end
    if not range_contains(proposed_ranges, visible_start, visible_end) then
      local description = proposed_count > 0 and ("changed proposed lines %d-%d"):format(visible_start, visible_end)
        or ("the deletion anchored at proposed line %d"):format(visible_start)
      return nil,
        {
          reason = "preview_change_not_visible",
          message = ("unfolded_ranges do not fully contain %s"):format(description),
        }
    end

    -- Side-by-side filler for a pure deletion is attached to the preceding
    -- proposed line, while unified virtual lines use the following line.
    if proposed_count == 0 and visible_start > 1 then
      proposed_visible[visible_start - 1] = true
    end

    for line = original_boundary, original_boundary + original_count - 1 do
      original_visible[line] = true
    end
    if original_count == 0 and #original_lines > 0 then
      local anchor = math.max(1, math.min(#original_lines, original_boundary))
      original_visible[anchor] = true
    end

    original_cursor = original_boundary + original_count
    proposed_cursor = proposed_boundary + proposed_count
  end

  while original_cursor <= #original_lines and proposed_cursor <= #proposed_lines do
    if proposed_visible[proposed_cursor] then
      original_visible[original_cursor] = true
    end
    original_cursor = original_cursor + 1
    proposed_cursor = proposed_cursor + 1
  end

  local original_ranges = flags_to_ranges(original_visible, #original_lines)
  if not original_ranges or #original_ranges == 0 then
    original_ranges = { { start_line = 1, end_line = 1 } }
  end
  local rendered_proposed_ranges = flags_to_ranges(proposed_visible, #proposed_lines)
  return {
    original = original_ranges,
    proposed = rendered_proposed_ranges,
    diff_result = diff_result,
  }
end

return M
