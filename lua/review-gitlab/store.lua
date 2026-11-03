local M = {}

local storage = require("review-gitlab.storage")

---@class Comment
---@field id string
---@field file string
---@field line number 1-based; 0 means a file-level comment
---@field line_end? number
---@field side? "old"|"new"
---@field text string
---@field created_at number
---@field uploaded? boolean set once the comment is posted to the MR
---@field uploaded_at? number
---@field discussion_id? string GitLab discussion id the comment was posted as
---@field revisions? CommentRevisions diff the comment's lines refer to

---@class CommentRevisions
---@field base_sha string old (left) side revision (a GitLab position's base_sha/start_sha)
---@field head_sha? string new (right) side revision, nil when it is the working tree
---@field base_ref? string raw ref base_sha was resolved from
---@field head_ref? string raw ref head_sha was resolved from

---@type table<string, Comment[]>
M.comments = {}

local id_counter = 0
local loaded = false

---@return string
local function generate_id()
  id_counter = id_counter + 1
  return string.format("comment_%d_%d", os.time(), id_counter)
end

local function persist()
  storage.save(M.comments)
end

function M.reset()
  M.comments = {}
  id_counter = 0
  loaded = false
end

function M.load()
  if loaded then
    return
  end
  M.comments = storage.load()
  -- Update id_counter to avoid collisions
  for _, comments in pairs(M.comments) do
    for _, comment in ipairs(comments) do
      local num = tonumber(comment.id:match("comment_%d+_(%d+)"))
      if num and num > id_counter then
        id_counter = num
      end
    end
  end
  loaded = true
end

---@param file string
---@param line number
---@param text string
---@param line_end? number
---@param side? "old"|"new"
---@param revisions? CommentRevisions diff revisions to anchor the comment to
---@return Comment
function M.add(file, line, text, line_end, side, revisions)
  if not M.comments[file] then
    M.comments[file] = {}
  end

  local comment = {
    id = generate_id(),
    file = file,
    line = line,
    line_end = (line_end and line_end ~= line) and line_end or nil,
    side = side or "new",
    text = text,
    created_at = os.time(),
    uploaded = false,
    revisions = revisions,
  }

  table.insert(M.comments[file], comment)
  persist()
  return comment
end

---@param id string
---@return Comment|nil
function M.get(id)
  for _, comments in pairs(M.comments) do
    for _, comment in ipairs(comments) do
      if comment.id == id then
        return comment
      end
    end
  end
  return nil
end

---@param file string
---@param side? "old"|"new"
---@return Comment[]
function M.get_for_file(file, side)
  local comments = M.comments[file] or {}
  if not side then
    return comments
  end
  local filtered = {}
  for _, comment in ipairs(comments) do
    if comment.line == 0 or (comment.side or "new") == side then
      table.insert(filtered, comment)
    end
  end
  return filtered
end

---@param file string
---@return Comment|nil
function M.get_file_comment(file)
  local comments = M.comments[file] or {}
  for _, comment in ipairs(comments) do
    if comment.line == 0 then
      return comment
    end
  end
  return nil
end

---@param file string
---@param line number
---@param side? "old"|"new"
---@return Comment|nil
function M.get_at_line(file, line, side)
  local comments = M.comments[file] or {}
  for _, comment in ipairs(comments) do
    local line_end = comment.line_end or comment.line
    if line >= comment.line and line <= line_end then
      if not side or (comment.side or "new") == side then
        return comment
      end
    end
  end
  return nil
end

---@param file string
---@param start_line number
---@param end_line number
---@param side? "old"|"new"
---@return Comment|nil
function M.get_overlapping(file, start_line, end_line, side)
  local comments = M.comments[file] or {}
  for _, comment in ipairs(comments) do
    local c_end = comment.line_end or comment.line
    if comment.line <= end_line and c_end >= start_line then
      if not side or (comment.side or "new") == side then
        return comment
      end
    end
  end
  return nil
end

---@param id string
---@param text string
---@return boolean
function M.update(id, text)
  local comment = M.get(id)
  if not comment then
    return false
  end
  comment.text = text
  persist()
  return true
end

---Mark a comment as uploaded to the MR (local flag, the primary signal for
---skipping it on a re-run). Stores the GitLab discussion id when known.
---@param id string
---@param discussion_id? string
---@return boolean
function M.mark_uploaded(id, discussion_id)
  local comment = M.get(id)
  if not comment then
    return false
  end
  comment.uploaded = true
  comment.uploaded_at = os.time()
  comment.discussion_id = discussion_id
  persist()
  return true
end

---Move a comment to new lines (used when the buffer it lives in was edited).
---@param id string
---@param line number
---@param line_end? number
---@return boolean
function M.move(id, line, line_end)
  local comment = M.get(id)
  if not comment then
    return false
  end
  comment.line = line
  comment.line_end = (line_end and line_end ~= line) and line_end or nil
  persist()
  return true
end

---@param id string
---@return boolean
function M.delete(id)
  for file, comments in pairs(M.comments) do
    for i, comment in ipairs(comments) do
      if comment.id == id then
        table.remove(comments, i)
        if #comments == 0 then
          M.comments[file] = nil
        end
        persist()
        return true
      end
    end
  end
  return false
end

---@return Comment[]
function M.get_all()
  local all = {}
  for _, comments in pairs(M.comments) do
    for _, comment in ipairs(comments) do
      table.insert(all, comment)
    end
  end
  table.sort(all, function(a, b)
    if a.file ~= b.file then
      return a.file < b.file
    end
    return a.line < b.line
  end)
  return all
end

---@return table<string, Comment[]>
function M.get_all_by_file()
  return M.comments
end

---@return number
function M.count()
  local count = 0
  for _, comments in pairs(M.comments) do
    count = count + #comments
  end
  return count
end

---Drop all comments for the current (repo, branch).
function M.clear()
  M.reset()
  storage.clear()
end

return M
