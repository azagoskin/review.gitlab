local M = {}

local store = require("review-gitlab.store")
local hooks = require("review-gitlab.hooks")
local popup = require("review-gitlab.popup")
local marks = require("review-gitlab.marks")
local utils = require("review-gitlab.utils")
local log = require("review-gitlab.log")

local function notify(msg, level)
  vim.notify(msg, level, { title = "review.gitlab" })
end

-- Перерисовать после изменения: панели ревью и буфер, где поставили замечание.
local function refresh_marks(bufnr)
  vim.schedule(function()
    marks.refresh()
    marks.render_plain_buffer(bufnr)
  end)
end

function M.add_at_cursor()
  local target_buf = vim.api.nvim_get_current_buf()
  local file, line, side = hooks.get_cursor_position()
  if not file or not line then
    notify("Не удалось определить позицию курсора", vim.log.levels.WARN)
    return
  end

  local existing = store.get_at_line(file, line, side)
  if existing then
    notify("На этой строке уже есть замечание. Используйте редактирование.", vim.log.levels.WARN)
    return
  end

  local revisions = hooks.get_revisions()
  popup.open(nil, function(text)
    if text then
      store.add(file, line, text, nil, side, revisions)
      log.write(("comment add: %s:%d side=%s"):format(file, line, tostring(side)))
      refresh_marks(target_buf)
      notify("Замечание добавлено", vim.log.levels.INFO)
    end
  end)
end

-- Совместимость: раньше открывало меню выбора типа, теперь просто добавляет.
function M.add_with_menu()
  M.add_at_cursor()
end

function M.file_comment()
  local target_buf = vim.api.nvim_get_current_buf()
  local file = hooks.get_cursor_position()
  if not file then
    notify("Не удалось определить файл", vim.log.levels.WARN)
    return
  end

  local existing = store.get_file_comment(file)
  if existing then
    popup.open(existing.text, function(text)
      if text then
        store.update(existing.id, text)
        refresh_marks(target_buf)
        notify("Комментарий к файлу обновлён", vim.log.levels.INFO)
      end
    end)
  else
    local revisions = hooks.get_revisions()
    popup.open(nil, function(text)
      if text then
        store.add(file, 0, text, nil, nil, revisions)
        log.write("file comment add: " .. file)
        refresh_marks(target_buf)
        notify("Добавлен комментарий к файлу", vim.log.levels.INFO)
      end
    end)
  end
end

---@param start_line? number по умолчанию — визуальное выделение
---@param end_line? number
function M.add_for_range(start_line, end_line)
  local target_buf = vim.api.nvim_get_current_buf()
  local file, side
  if start_line and end_line then
    file, _, side = hooks.get_cursor_position()
    if start_line > end_line then
      start_line, end_line = end_line, start_line
    end
  else
    file, start_line, end_line, side = hooks.get_visual_range()
  end
  if not file or not start_line or not end_line then
    notify("Не удалось определить выделение", vim.log.levels.WARN)
    return
  end

  local existing = store.get_overlapping(file, start_line, end_line, side)
  if existing then
    notify("В этом диапазоне уже есть замечание. Используйте редактирование.", vim.log.levels.WARN)
    return
  end

  local revisions = hooks.get_revisions()
  popup.open(nil, function(text)
    if text then
      store.add(file, start_line, text, end_line, side, revisions)
      log.write(("comment add range: %s:%d-%d side=%s"):format(file, start_line, end_line, tostring(side)))
      refresh_marks(target_buf)
      notify("Замечание добавлено", vim.log.levels.INFO)
    end
  end)
end

function M.edit_at_cursor()
  local target_buf = vim.api.nvim_get_current_buf()
  local file, line, side = hooks.get_cursor_position()
  if not file or not line then
    notify("Не удалось определить позицию курсора", vim.log.levels.WARN)
    return
  end

  local comment = store.get_at_line(file, line, side)
  if not comment and line == 1 then
    comment = store.get_file_comment(file)
  end
  if not comment then
    notify("Под курсором нет замечания", vim.log.levels.WARN)
    return
  end

  popup.open(comment.text, function(text)
    if text then
      store.update(comment.id, text)
      refresh_marks(target_buf)
      notify("Замечание обновлено", vim.log.levels.INFO)
    end
  end)
end

function M.delete_at_cursor()
  local target_buf = vim.api.nvim_get_current_buf()
  local file, line, side = hooks.get_cursor_position()
  if not file or not line then
    notify("Не удалось определить позицию курсора", vim.log.levels.WARN)
    return
  end

  local comment = store.get_at_line(file, line, side)
  if not comment and line == 1 then
    comment = store.get_file_comment(file)
  end
  if not comment then
    notify("Под курсором нет замечания", vim.log.levels.WARN)
    return
  end

  vim.ui.select({ "Да", "Нет" }, {
    prompt = "Удалить это замечание?",
  }, function(choice)
    if choice == "Да" then
      store.delete(comment.id)
      refresh_marks(target_buf)
      notify("Замечание удалено", vim.log.levels.INFO)
    end
  end)
end

function M.goto_next()
  local file, line, side = hooks.get_cursor_position()
  if not file then
    return
  end

  local comments = store.get_for_file(file, side)
  for _, comment in ipairs(comments) do
    if comment.line > line then
      vim.api.nvim_win_set_cursor(0, { comment.line, 0 })
      return
    end
  end

  notify("Больше замечаний в этом файле нет", vim.log.levels.INFO)
end

function M.goto_prev()
  local file, line, side = hooks.get_cursor_position()
  if not file then
    return
  end

  local comments = store.get_for_file(file, side)
  for i = #comments, 1, -1 do
    local comment = comments[i]
    if comment.line < line then
      vim.api.nvim_win_set_cursor(0, { comment.line, 0 })
      return
    end
  end

  notify("Предыдущих замечаний в этом файле нет", vim.log.levels.INFO)
end

function M.list()
  local all_comments = store.get_all()

  if #all_comments == 0 then
    notify("Пока нет замечаний", vim.log.levels.INFO)
    return
  end

  local items = {}
  for _, comment in ipairs(all_comments) do
    local icon = comment.uploaded and "✓" or "●"
    local location
    local is_old = (comment.side or "new") == "old"
    if comment.line == 0 then
      location = comment.file
    elseif is_old then
      if comment.line_end and comment.line_end ~= comment.line then
        location = string.format("%s:~%d-~%d", comment.file, comment.line, comment.line_end)
      else
        location = string.format("%s:~%d", comment.file, comment.line)
      end
    elseif comment.line_end and comment.line_end ~= comment.line then
      location = string.format("%s:%d-%d", comment.file, comment.line, comment.line_end)
    else
      location = string.format("%s:%d", comment.file, comment.line)
    end
    local display = string.format("%s %s  %s", icon, location, comment.text)
    table.insert(items, { display = display, comment = comment })
  end

  vim.ui.select(items, {
    prompt = "Замечания:",
    format_item = function(item)
      return item.display
    end,
  }, function(choice)
    if not choice then
      return
    end

    local comment = choice.comment

    -- В ревью открываем файл через explorer codediff; иначе — напрямую.
    local explorer = hooks.get_explorer(vim.api.nvim_get_current_tabpage())
    if explorer then
      local file_data
      for _, node in ipairs(require("codediff.ui.explorer.tree").get_all_files(explorer.tree)) do
        if node.data.path == comment.file then
          file_data = node.data
          break
        end
      end
      if not file_data then
        notify("Файла нет в списке этого ревью: " .. comment.file, vim.log.levels.WARN)
        return
      end
      explorer.on_file_select(file_data)
    else
      local root = utils.git_root()
      if not root then
        notify("Не git-репозиторий", vim.log.levels.WARN)
        return
      end
      vim.cmd.edit(vim.fn.fnameescape(root .. "/" .. comment.file))
    end

    vim.defer_fn(function()
      if explorer then
        local original_win, modified_win = require("codediff.ui.lifecycle").get_windows(vim.api.nvim_get_current_tabpage())
        local win = comment.side == "old" and original_win or modified_win
        if win and vim.api.nvim_win_is_valid(win) then
          vim.api.nvim_set_current_win(win)
        end
      end
      local target_line = comment.line == 0 and 1 or comment.line
      pcall(vim.api.nvim_win_set_cursor, 0, { target_line, 0 })
    end, 100)
  end)
end

return M
