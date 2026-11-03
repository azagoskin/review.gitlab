local M = {}

---@class DiffLine
---@field kind "context"|"added"|"removed"
---@field old_line number? line number on the old side
---@field new_line number? line number on the new side

---@class FileDiff
---@field old_path string
---@field new_path string
---@field by_new table<number, DiffLine> lines keyed by their new-side number
---@field by_old table<number, DiffLine> lines keyed by their old-side number

---Parse one file's unified-diff text into lookups by old- and new-side line.
---Only lines present in a hunk can carry a GitLab discussion position, so a
---lookup miss means "not commentable in this MR's diff".
---@param old_path string
---@param new_path string
---@param text string the `diff` field from a GitLab MR diff entry
---@return FileDiff
function M.parse_file(old_path, new_path, text)
  local file = { old_path = old_path, new_path = new_path, by_new = {}, by_old = {} }
  local old_line, new_line
  for line in (text .. "\n"):gmatch("(.-)\n") do
    local os_, ns = line:match("^@@ %-(%d+),?%d* %+(%d+),?%d* @@")
    if os_ then
      old_line, new_line = tonumber(os_), tonumber(ns)
    elseif old_line then
      local tag = line:sub(1, 1)
      if tag == " " then
        local entry = { kind = "context", old_line = old_line, new_line = new_line }
        file.by_old[old_line] = entry
        file.by_new[new_line] = entry
        old_line, new_line = old_line + 1, new_line + 1
      elseif tag == "+" then
        file.by_new[new_line] = { kind = "added", new_line = new_line }
        new_line = new_line + 1
      elseif tag == "-" then
        file.by_old[old_line] = { kind = "removed", old_line = old_line }
        old_line = old_line + 1
      end
      -- "\ No newline at end of file" and any stray lines are ignored.
    end
  end
  return file
end

---Index a GitLab MR `/diffs` response by both paths, so a comment's file (which
---is the new path on the new side, the old path on the old side) always hits.
---@param entries table[] decoded MR diff entries ({ old_path, new_path, diff })
---@return table<string, FileDiff>
function M.index(entries)
  local by_path = {}
  for _, e in ipairs(entries or {}) do
    local fd = M.parse_file(e.old_path, e.new_path, e.diff or "")
    by_path[e.new_path] = fd
    by_path[e.old_path] = fd
  end
  return by_path
end

return M
