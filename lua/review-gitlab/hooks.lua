local M = {}

local marks = require("review-gitlab.marks")
local config = require("review-gitlab.config")
local log = require("review-gitlab.log")
local normalize_path = require("review-gitlab.utils").normalize_path

---@type number|nil текущая вкладка с активной codediff-сессией
local current_tabpage = nil

---@type number|nil augroup для буферных событий
local buf_augroup = nil

---@type table<number, boolean> вкладки, у которых правую панель уже фокусировали
local focused_tabpages = {}

---@type table<number, {modifiable: boolean, readonly: boolean}> опции буферов до readonly
local saved_buf_options = {}

---Сделать буфер readonly на время ревью, запомнив прежнее состояние.
---@param bufnr number|nil
local function make_readonly(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if not saved_buf_options[bufnr] then
    saved_buf_options[bufnr] = {
      modifiable = vim.api.nvim_get_option_value("modifiable", { buf = bufnr }),
      readonly = vim.api.nvim_get_option_value("readonly", { buf = bufnr }),
    }
  end
  vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
  vim.api.nvim_set_option_value("readonly", true, { buf = bufnr })
end

---Вернуть modifiable/readonly на всех буферах, которых касался make_readonly.
function M.restore_buffer_options()
  for bufnr, opts in pairs(saved_buf_options) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_set_option_value("modifiable", opts.modifiable, { buf = bufnr })
      vim.api.nvim_set_option_value("readonly", opts.readonly, { buf = bufnr })
    end
  end
  saved_buf_options = {}
end

---Привести значение пути codediff к строке.
---codediff >= июль 2026 отдаёт из lifecycle.get_paths таблицу Path
---({ relative, absolute }); старые версии — строку.
---@param path string|table|nil
---@return string|nil
local function to_path_string(path)
  if type(path) == "table" then
    if path.absolute and path.absolute ~= "" then
      return path.absolute
    end
    if path.relative and path.relative ~= "" then
      return path.relative
    end
    return nil
  end
  if path == "" then
    return nil
  end
  return path
end

---Подсветка синтаксиса буфера по пути через treesitter (без FileType-autocmd,
---чтобы не задеть другие плагины).
---@param bufnr number
---@param path string|table|nil
local function set_buffer_filetype(bufnr, path)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  path = to_path_string(path)
  if not path then
    return
  end

  local ft = vim.filetype.match({ filename = path, buf = bufnr })
  if ft then
    local lang = vim.treesitter.language.get_lang(ft) or ft
    local ts_ok = pcall(vim.treesitter.start, bufnr, lang)
    if not ts_ok then
      vim.api.nvim_set_option_value("filetype", ft, { buf = bufnr })
    end
  end
end

---@return number|nil tabpage id
function M.get_current_tabpage()
  return current_tabpage
end

---@return table|nil codediff lifecycle module
local function get_lifecycle()
  local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
  if not ok then
    return nil
  end
  return lifecycle
end

---@return table|nil codediff session
function M.get_session()
  if not current_tabpage then
    return nil
  end
  local lifecycle = get_lifecycle()
  if not lifecycle then
    return nil
  end
  return lifecycle.get_session(current_tabpage)
end

---Проводник (explorer) codediff для вкладки.
---@param tabpage number
---@return table|nil explorer
function M.get_explorer(tabpage)
  local lifecycle = get_lifecycle()
  if not lifecycle then
    return nil
  end
  if lifecycle.get_explorer then
    return lifecycle.get_explorer(tabpage)
  end
  if lifecycle.get_panel then
    local panel = lifecycle.get_panel(tabpage)
    if panel and panel.name == "explorer" then
      return panel.view
    end
  end
  return nil
end

---Привести путь к относительному от git-root для согласованного хранения/поиска.
---@param path string|nil
---@param lifecycle table
---@param tabpage number
---@return string|nil
local function relativize_path(path, lifecycle, tabpage)
  path = to_path_string(path)
  if not path then
    return nil
  end
  local git_ctx = lifecycle.get_git_context(tabpage)
  if git_ctx and git_ctx.git_root then
    local abs = vim.fn.fnamemodify(path, ":p")
    return normalize_path(abs:gsub("^" .. vim.pesc(git_ctx.git_root) .. "/", ""))
  end
  return normalize_path(vim.fn.fnamemodify(path, ":."))
end

---Файл-цель замечания в обычном буфере (без codediff): путь относительно
---git-root, сторона "new".
---@param bufnr? number
---@return string|nil file
function M.plain_buffer_file(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].buftype ~= "" then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" or name:match("^%a[%w+.-]*://") then
    return nil
  end
  return require("review-gitlab.utils").relative_to_root(name)
end

---@return string|nil file path
---@return number|nil line number
---@return "old"|"new"|nil side
function M.get_cursor_position()
  local lifecycle = get_lifecycle()
  local sess = lifecycle and current_tabpage and lifecycle.get_session(current_tabpage)
  if not sess then
    -- Ревью не открыто: замечания всё равно можно ставить на любой файл репо
    local file = M.plain_buffer_file()
    if not file then
      return nil, nil, nil
    end
    return file, vim.api.nvim_win_get_cursor(0)[1], "new"
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local current_buf = vim.api.nvim_get_current_buf()

  local orig_path, mod_path = lifecycle.get_paths(current_tabpage)
  orig_path, mod_path = to_path_string(orig_path), to_path_string(mod_path)
  local orig_buf, mod_buf = lifecycle.get_buffers(current_tabpage)

  local file_path
  local side
  if current_buf == orig_buf then
    file_path = orig_path
    side = "old"
  elseif current_buf == mod_buf then
    file_path = mod_path
    side = "new"
  else
    local bufname = vim.api.nvim_buf_get_name(current_buf)
    if bufname:match("^codediff://") then
      file_path = mod_path or orig_path
      side = "new"
    else
      local file = M.plain_buffer_file(current_buf)
      if not file then
        return nil, nil, nil
      end
      return file, cursor[1], "new"
    end
  end

  if not file_path then
    return nil, nil, nil
  end

  return relativize_path(file_path, lifecycle, current_tabpage), cursor[1], side
end

---@return string|nil file path
---@return number|nil start line
---@return number|nil end line
---@return "old"|"new"|nil side
function M.get_visual_range()
  local start_line = vim.fn.line("'<")
  local end_line = vim.fn.line("'>")
  if start_line > end_line then
    start_line, end_line = end_line, start_line
  end

  local file, _, side = M.get_cursor_position()
  if not file then
    return nil, nil, nil, nil
  end

  return file, start_line, end_line, side
end

---Разрешить исходные ref'ы сессии.
---@param sess table
---@param lifecycle table
---@return table source_revisions ({ original, modified }), {} если неизвестно
local function session_source_refs(sess, lifecycle)
  if sess.source_revisions then
    return sess.source_revisions
  end
  if current_tabpage and lifecycle.get_panel then
    local panel = lifecycle.get_panel(current_tabpage)
    if panel and panel.data and panel.data.source_revisions then
      return panel.data.source_revisions
    end
  end
  return {}
end

---Ревизии, которые сейчас сравнивает ревью, чтобы привязать замечания к
---конкретному диффу при загрузке (позиция discussion в MR GitLab).
---nil вне сессии ревью.
---@return CommentRevisions|nil
function M.get_revisions()
  local lifecycle = get_lifecycle()
  local sess = lifecycle and current_tabpage and lifecycle.get_session(current_tabpage)
  if not sess then
    return nil
  end
  local refs = session_source_refs(sess, lifecycle)
  local function sha(v)
    return (v and v ~= "WORKING") and v or nil
  end
  local base_sha = sha(sess.original_revision or refs.original)
  local head_sha = sha(sess.modified_revision or refs.modified)
  log.write(("hooks.get_revisions: base_sha=%s head_sha=%s"):format(tostring(base_sha), tostring(head_sha)))
  if not base_sha and not head_sha then
    return nil
  end
  return {
    base_sha = base_sha,
    head_sha = head_sha,
    base_ref = refs.original,
    head_ref = refs.modified,
  }
end

---@return number|nil original buffer
---@return number|nil modified buffer
function M.get_buffers()
  local lifecycle = get_lifecycle()
  if not lifecycle or not current_tabpage then
    return nil, nil
  end
  return lifecycle.get_buffers(current_tabpage)
end

---@return string|nil original path
---@return string|nil modified path
function M.get_paths()
  local lifecycle = get_lifecycle()
  if not lifecycle or not current_tabpage then
    return nil, nil
  end
  local orig_path, mod_path = lifecycle.get_paths(current_tabpage)
  return relativize_path(orig_path, lifecycle, current_tabpage),
    relativize_path(mod_path, lifecycle, current_tabpage)
end

-- Вызывается при создании codediff-сессии
function M.on_session_created(tabpage)
  current_tabpage = tabpage

  local lifecycle = get_lifecycle()
  if not lifecycle then
    return
  end

  local orig_buf, mod_buf = lifecycle.get_buffers(tabpage)
  log.write(("hooks.on_session_created: tab=%s orig_buf=%s mod_buf=%s"):format(
    tostring(tabpage), tostring(orig_buf), tostring(mod_buf)))

  local raw_orig_path, raw_mod_path = lifecycle.get_paths(tabpage)
  set_buffer_filetype(orig_buf, raw_orig_path)
  set_buffer_filetype(mod_buf, raw_mod_path)

  if config.get().codediff.readonly then
    make_readonly(orig_buf)
    make_readonly(mod_buf)
  end

  if buf_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, buf_augroup)
  end
  buf_augroup = vim.api.nvim_create_augroup("review_gitlab_buf_marks", { clear = true })

  vim.api.nvim_create_autocmd("BufEnter", {
    group = buf_augroup,
    callback = function()
      if vim.api.nvim_get_current_tabpage() ~= current_tabpage then
        return
      end
      local bufnr = vim.api.nvim_get_current_buf()
      local ob, mb = lifecycle.get_buffers(current_tabpage)
      if bufnr ~= ob and bufnr ~= mb then
        return
      end
      marks.refresh()
    end,
  })

  vim.defer_fn(function()
    marks.refresh()
  end, 100)

  if not focused_tabpages[tabpage] then
    focused_tabpages[tabpage] = true
    vim.defer_fn(function()
      M._focus_modified_pane(lifecycle, tabpage)
    end, 150)
  end
end

function M._focus_modified_pane(lifecycle, tabpage)
  local cur_cfg = vim.api.nvim_win_get_config(vim.api.nvim_get_current_win())
  if cur_cfg.relative ~= "" then
    return
  end
  local sess = lifecycle.get_session(tabpage)
  if sess and sess.modified_win and vim.api.nvim_win_is_valid(sess.modified_win) then
    vim.api.nvim_set_current_win(sess.modified_win)
  end
end

-- Вызывается при закрытии codediff-сессии
function M.on_session_closed()
  if current_tabpage then
    focused_tabpages[current_tabpage] = nil
  end
  current_tabpage = nil
  M.restore_buffer_options()
  if buf_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, buf_augroup)
    buf_augroup = nil
  end
  require("review-gitlab.keymaps").cleanup()
end

-- Вызывается при смене файла в explorer-режиме
function M.on_file_changed(tabpage)
  current_tabpage = tabpage

  local lifecycle = get_lifecycle()
  if not lifecycle then
    return
  end

  local orig_buf, mod_buf = lifecycle.get_buffers(tabpage)

  local raw_orig_path, raw_mod_path = lifecycle.get_paths(tabpage)
  set_buffer_filetype(orig_buf, raw_orig_path)
  set_buffer_filetype(mod_buf, raw_mod_path)

  if config.get().codediff.readonly then
    make_readonly(orig_buf)
    make_readonly(mod_buf)
  end

  vim.defer_fn(function()
    marks.refresh()
  end, 50)
end

return M
