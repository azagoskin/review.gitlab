local M = {}

---The hidden marker appended to every posted note, so re-running the upload
---recognises its own notes and never posts a comment twice.
---@param cfg ReviewGitlabConfig
---@param id string review.nvim comment id
---@return string
function M.marker_line(cfg, id)
  return string.format("<!-- %s:%s -->", cfg.marker, id)
end

---Comment ids already present in a block of note bodies, as a set.
---@param text string? concatenated discussion/note bodies
---@param cfg ReviewGitlabConfig
---@return table<string, boolean>
function M.extract_ids(text, cfg)
  local ids = {}
  if text then
    for id in text:gmatch("<!%-%- " .. vim.pesc(cfg.marker) .. ":(%S-) %-%->") do
      ids[id] = true
    end
  end
  return ids
end

---Тело заметки: текст замечания плюс скрытый маркер идемпотентности. Для
---многострочных замечаний добавляется строка-подсказка о диапазоне строк.
---@param cfg ReviewGitlabConfig
---@param comment Comment
---@return string
function M.build_body(cfg, comment)
  local text = comment.text
  if comment.line_end and comment.line_end ~= comment.line then
    text = string.format("_(строки %d–%d)_\n\n%s", comment.line, comment.line_end, text)
  end
  return string.format("%s\n\n%s", text, M.marker_line(cfg, comment.id))
end

---Build a GitLab discussion position for an inline comment. The old/new line
---pairing is read from the MR diff: context lines carry both numbers, added
---lines only new, removed lines only old — matching what GitLab requires.
---@param comment Comment
---@param file_diff FileDiff the MR diff for the comment's file
---@param diff_refs { base_sha: string, start_sha: string, head_sha: string }
---@return table? position, string? err
function M.build_position(comment, file_diff, diff_refs)
  local side = comment.side or "new"
  local entry = side == "old" and file_diff.by_old[comment.line] or file_diff.by_new[comment.line]
  if not entry then
    return nil, "line not part of the MR diff"
  end
  return {
    position_type = "text",
    base_sha = diff_refs.base_sha,
    start_sha = diff_refs.start_sha,
    head_sha = diff_refs.head_sha,
    old_path = file_diff.old_path,
    new_path = file_diff.new_path,
    old_line = entry.old_line,
    new_line = entry.new_line,
  }
end

return M
