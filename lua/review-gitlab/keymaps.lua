local M = {}

local hooks = require("review-gitlab.hooks")
local config = require("review-gitlab.config")
local comments = require("review-gitlab.comments")

-- Какие буферы получили keymaps и что именно было назначено
local keymapped_buffers = {}

---@param key string|false|nil
---@return boolean
local function is_enabled(key)
  return key ~= nil and key ~= false and key ~= ""
end

---@param bufnr number
---@param mode string
---@param lhs string|nil
local function del_keymap(bufnr, mode, lhs)
  if lhs and vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.keymap.del, mode, lhs, { buffer = bufnr })
  end
end

---@param bufnr number
local function clear_buffer_keymaps(bufnr)
  local tracked = keymapped_buffers[bufnr]
  if tracked then
    for _, entry in ipairs(tracked) do
      del_keymap(bufnr, entry[1], entry[2])
    end
  end
end

---@param key string
---@return string
local function format_key(key)
  local inner = key:match("^<(.+)>$")
  if not inner then return key end
  if inner:lower() == "leader" or inner:lower() == "localleader" then return key end
  inner = inner:gsub("^C%-", "Ctrl-")
  return inner
end

---@param entries {key: string, desc: string}[]
---@param title string
---@param lines string[]
---@param max_key_width number
local function add_section(entries, title, lines, max_key_width)
  if #entries == 0 then return end
  table.insert(lines, "")
  table.insert(lines, "  " .. title)
  for _, entry in ipairs(entries) do
    local padding = string.rep(" ", max_key_width - #entry.key + 3)
    table.insert(lines, "   " .. entry.key .. padding .. entry.desc)
  end
end

local help_popup = nil

local function close_help()
  if help_popup then
    help_popup:unmount()
    help_popup = nil
  end
end

local function show_help()
  if help_popup then
    close_help()
    return
  end

  local cfg = config.get()
  local km = cfg.keymaps
  local readonly = cfg.codediff.readonly

  local comment_entries = {}
  local nav_entries = {}
  local action_entries = {}

  local function entry(key_name, desc, tbl)
    local key = km[key_name]
    if not is_enabled(key) then return end
    table.insert(tbl, { key = format_key(key), desc = desc })
  end

  if readonly then
    entry("readonly_add", "Добавить замечание", comment_entries)
    entry("readonly_edit", "Редактировать", comment_entries)
    entry("readonly_delete", "Удалить", comment_entries)
    entry("readonly_add_file", "Комментарий к файлу", comment_entries)
  else
    entry("add_comment", "Добавить замечание", comment_entries)
    entry("add_file_comment", "Комментарий к файлу", comment_entries)
    entry("edit_comment", "Редактировать", comment_entries)
    entry("delete_comment", "Удалить", comment_entries)
  end

  entry("next_comment", "Следующее замечание", nav_entries)
  entry("prev_comment", "Предыдущее замечание", nav_entries)
  entry("next_file", "Следующий файл", nav_entries)
  entry("prev_file", "Предыдущий файл", nav_entries)
  entry("toggle_file_panel", "Панель файлов", nav_entries)
  entry("list_comments", "Список замечаний", nav_entries)

  entry("upload", "Загрузить в MR", action_entries)
  entry("clear_comments", "Удалить все замечания", action_entries)
  entry("toggle_readonly", "Readonly/редактирование", action_entries)
  entry("close", "Закрыть ревью", action_entries)
  entry("show_help", "Эта справка", action_entries)
  table.insert(action_entries, { key = "t", desc = "Переключить раскладку" })
  table.insert(action_entries, { key = "g?", desc = "Справка codediff" })

  local all_entries = {}
  vim.list_extend(all_entries, comment_entries)
  vim.list_extend(all_entries, nav_entries)
  vim.list_extend(all_entries, action_entries)

  local max_key_width = 0
  for _, e in ipairs(all_entries) do
    max_key_width = math.max(max_key_width, #e.key)
  end

  local lines = {}
  add_section(comment_entries, "Замечания", lines, max_key_width)
  add_section(nav_entries, "Навигация", lines, max_key_width)
  add_section(action_entries, "Действия", lines, max_key_width)
  table.insert(lines, "")

  local max_line_width = 0
  for _, line in ipairs(lines) do
    max_line_width = math.max(max_line_width, #line)
  end

  local width = math.max(max_line_width + 2, 30)
  local height = #lines

  local ok_popup, Popup = pcall(require, "nui.popup")
  if not ok_popup then return end
  help_popup = Popup({
    position = "50%",
    size = { width = width, height = height },
    border = {
      style = "rounded",
      text = { top = " Горячие клавиши ", top_align = "center" },
    },
    buf_options = { modifiable = false, buftype = "nofile" },
  })

  help_popup:mount()

  local buf = help_popup.bufnr
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  vim.api.nvim_set_current_win(help_popup.winid)

  local map_opts = { noremap = true, nowait = true }
  help_popup:map("n", "?", close_help, map_opts)
  help_popup:map("n", "q", close_help, map_opts)
  help_popup:map("n", "<Esc>", close_help, map_opts)
end

-- Прыгнуть к первому ханку файла в текущей панели диффа
local function jump_to_first_hunk()
  local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
  if not ok then return end
  local tabpage = vim.api.nvim_get_current_tabpage()
  local session = lifecycle.get_session(tabpage)
  if not session or not session.stored_diff_result then return end
  local diff_result = session.stored_diff_result
  if #diff_result.changes == 0 then return end

  local orig_buf, mod_buf = lifecycle.get_buffers(tabpage)
  local current_buf = vim.api.nvim_get_current_buf()
  local is_original = current_buf == orig_buf

  local first_hunk = diff_result.changes[1]
  local target_line = is_original and first_hunk.original.start_line or first_hunk.modified.start_line
  pcall(vim.api.nvim_win_set_cursor, 0, { target_line, 0 })
end

---@param bufnr number
local function set_buffer_keymaps(bufnr)
  clear_buffer_keymaps(bufnr)

  local cfg = config.get()
  local km = cfg.keymaps
  local readonly = cfg.codediff.readonly
  local mapped = {}

  local function set(lhs, rhs, desc)
    if is_enabled(lhs) then
      vim.keymap.set("n", lhs, rhs, { buffer = bufnr, noremap = true, silent = true, nowait = true, desc = desc })
      table.insert(mapped, { "n", lhs })
    end
  end

  local function set_visual(lhs, rhs, desc)
    if is_enabled(lhs) then
      vim.keymap.set("x", lhs, rhs, { buffer = bufnr, noremap = true, silent = true, nowait = true, desc = desc })
      table.insert(mapped, { "x", lhs })
    end
  end

  -- Навигация по файлам через собственный explorer codediff
  local function navigate(direction)
    return function()
      local explorer_obj = hooks.get_explorer(vim.api.nvim_get_current_tabpage())
      if not explorer_obj then return end
      require("codediff.ui.explorer")["navigate_" .. direction](explorer_obj)
      vim.defer_fn(jump_to_first_hunk, 100)
    end
  end

  if readonly then
    set(km.readonly_add, function() comments.add_at_cursor() end, "Добавить замечание")
    set_visual(km.readonly_add, ":<C-u>lua require('review-gitlab.comments').add_for_range()<CR>", "Замечание на выделение")
    set(km.readonly_add_file, function() comments.file_comment() end, "Комментарий к файлу")
    set(km.readonly_delete, function() comments.delete_at_cursor() end, "Удалить замечание")
    set(km.readonly_edit, function() comments.edit_at_cursor() end, "Редактировать замечание")
  else
    set(km.add_comment, function() comments.add_at_cursor() end, "Добавить замечание")
    set_visual(km.add_comment, ":<C-u>lua require('review-gitlab.comments').add_for_range()<CR>", "Замечание на выделение")
    set(km.add_file_comment, function() comments.file_comment() end, "Комментарий к файлу")
    set(km.delete_comment, function() comments.delete_at_cursor() end, "Удалить замечание")
    set(km.edit_comment, function() comments.edit_at_cursor() end, "Редактировать замечание")
  end

  set(km.list_comments, function() comments.list() end, "Список замечаний")
  set(km.upload, function() require("review-gitlab").upload({}) end, "Загрузить замечания в MR")
  set(km.clear_comments, function() require("review-gitlab").clear() end, "Удалить все замечания")
  set(km.next_comment, function() comments.goto_next() end, "Следующее замечание")
  set(km.prev_comment, function() comments.goto_prev() end, "Предыдущее замечание")

  set(km.next_file, navigate("next"), "Следующий файл")
  set(km.prev_file, navigate("prev"), "Предыдущий файл")
  set(km.toggle_file_panel, function()
    local tabpage = vim.api.nvim_get_current_tabpage()
    local explorer_obj = hooks.get_explorer(tabpage)
    if explorer_obj then
      require("codediff.ui.explorer").toggle_visibility(explorer_obj)
    end
  end, "Панель файлов")
  set(km.close, function() require("review-gitlab").close() end, "Закрыть ревью")
  set(km.toggle_readonly, function() require("review-gitlab").toggle_readonly() end, "Readonly/редактирование")
  set(km.show_help, show_help, "Справка")

  keymapped_buffers[bufnr] = mapped
end

local augroup = nil

---@param tabpage number
function M.setup_keymaps(tabpage)
  local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
  if not ok then
    vim.notify("codediff.ui.lifecycle недоступен", vim.log.levels.WARN, { title = "review.gitlab" })
    return
  end

  if augroup then
    vim.api.nvim_del_augroup_by_id(augroup)
  end
  augroup = vim.api.nvim_create_augroup("review_gitlab_keymaps", { clear = true })

  for bufnr in pairs(keymapped_buffers) do
    clear_buffer_keymaps(bufnr)
  end
  keymapped_buffers = {}

  local orig_buf, mod_buf = lifecycle.get_buffers(tabpage)
  for _, bufnr in ipairs({ orig_buf, mod_buf }) do
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      set_buffer_keymaps(bufnr)
    end
  end

  vim.api.nvim_create_autocmd("BufEnter", {
    group = augroup,
    callback = function()
      if vim.api.nvim_get_current_tabpage() ~= tabpage then return end
      local win_config = vim.api.nvim_win_get_config(0)
      if win_config.relative ~= "" then return end
      if not lifecycle.get_session(tabpage) then return end
      local bufnr = vim.api.nvim_get_current_buf()
      local ob, mb = lifecycle.get_buffers(tabpage)
      if bufnr ~= ob and bufnr ~= mb then return end
      set_buffer_keymaps(bufnr)
    end,
  })
end

function M.clear_keymaps()
  for bufnr in pairs(keymapped_buffers) do
    clear_buffer_keymaps(bufnr)
  end
  keymapped_buffers = {}
end

function M.cleanup()
  if augroup then
    vim.api.nvim_del_augroup_by_id(augroup)
    augroup = nil
  end
  close_help()
  M.clear_keymaps()
end

M._test = {
  format_key = format_key,
  add_section = add_section,
  is_enabled = is_enabled,
}

return M
