local M = {}

local config = require("review-gitlab.config")
local highlights = require("review-gitlab.highlights")
local hooks = require("review-gitlab.hooks")
local keymaps = require("review-gitlab.keymaps")
local storage = require("review-gitlab.storage")
local store = require("review-gitlab.store")
local log = require("review-gitlab.log")

local initialized = false
local augroup = nil

---@param opts? ReviewGitlabConfig
function M.setup(opts)
  config.setup(opts)
  highlights.setup()

  if initialized then
    return
  end

  augroup = vim.api.nvim_create_augroup("review_gitlab", { clear = true })

  vim.api.nvim_create_autocmd("TabEnter", {
    group = augroup,
    callback = function()
      vim.defer_fn(function()
        M._check_codediff_session()
      end, 100)
    end,
  })

  vim.api.nvim_create_autocmd("TabClosed", {
    group = augroup,
    callback = function()
      hooks.on_session_closed()
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group = augroup,
    pattern = "CodeDiffOpen",
    callback = function()
      vim.defer_fn(function()
        M._check_codediff_session()
      end, 100)
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group = augroup,
    pattern = "CodeDiffFileSelect",
    callback = function()
      vim.defer_fn(function()
        M._on_file_select()
      end, 100)
    end,
  })

  -- Замечания живут и на обычных файлах: рисуем их при появлении такого буфера
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = augroup,
    callback = function(ev)
      local file = hooks.plain_buffer_file(ev.buf)
      if not file then
        return
      end
      local orig_buf, mod_buf = hooks.get_buffers()
      if ev.buf == orig_buf or ev.buf == mod_buf then
        return
      end
      store.load()
      if #store.get_for_file(file) > 0 then
        require("review-gitlab.marks").render_for_buffer(ev.buf, "new", file)
      end
    end,
  })

  -- Правки двигают extmark'и; на записи — переносим сохранённые строки
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = augroup,
    callback = function(ev)
      if hooks.plain_buffer_file(ev.buf) then
        require("review-gitlab.marks").sync_positions(ev.buf)
      end
    end,
  })

  initialized = true
end

-- Смена файла: обновить hooks/keymaps без перехвата фокуса
function M._on_file_select()
  local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
  if not ok then
    return
  end

  local tabpage = vim.api.nvim_get_current_tabpage()
  local sess = lifecycle.get_session(tabpage)
  if not sess then
    return
  end

  hooks.on_file_changed(tabpage)
  keymaps.setup_keymaps(tabpage)
end

-- Проверить, является ли текущая вкладка codediff-сессией, и настроить hooks/keymaps
function M._check_codediff_session()
  local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
  if not ok then
    return
  end

  local tabpage = vim.api.nvim_get_current_tabpage()
  local sess = lifecycle.get_session(tabpage)
  if not sess then
    return
  end

  hooks.on_session_created(tabpage)
  keymaps.setup_keymaps(tabpage)
end

---@param opts { args: string[] } аргументы :CodeDiff
local function open_codediff(opts)
  local ok, _ = pcall(require, "codediff")
  if not ok then
    vim.notify("Требуется codediff.nvim", vim.log.levels.ERROR, { title = "review.gitlab" })
    return
  end

  store.load()

  log.write("open_codediff args=" .. table.concat(opts.args, " "))
  vim.cmd({ cmd = "CodeDiff", args = opts.args })

  local attempts = 0
  local max_attempts = 5
  local function try_setup()
    attempts = attempts + 1
    local lifecycle_ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
    if lifecycle_ok then
      local tabpage = vim.api.nvim_get_current_tabpage()
      local sess = lifecycle.get_session(tabpage)
      if sess then
        M._check_codediff_session()
        return
      end
    end
    if attempts < max_attempts then
      vim.defer_fn(try_setup, 100)
    end
  end
  vim.defer_fn(try_setup, 200)
end

---Открыть дифф выбранного MR. Слева — левая ревизия MR (start_sha/base_sha,
---целевая сторона), справа — head_sha (source). Диапазон задаётся точными SHA
---из MR, чтобы inline-замечания гарантированно совпали с диффом GitLab.
---@param mr table { iid, diff_refs = { base_sha, start_sha, head_sha }, source_branch, target_branch, ... }
function M.open_mr(mr)
  local refs = mr.diff_refs or {}
  local left = refs.start_sha or refs.base_sha
  local right = refs.head_sha
  if not left or not right then
    vim.notify("У MR !" .. tostring(mr.iid) .. " нет diff_refs (base/head SHA)", vim.log.levels.ERROR, { title = "review.gitlab" })
    return
  end

  storage.save_mr(mr)
  log.write(("open_mr iid=%s  %s...%s  (%s -> %s)"):format(
    tostring(mr.iid), left:sub(1, 8), right:sub(1, 8),
    tostring(mr.source_branch), tostring(mr.target_branch)))

  open_codediff({ args = { left, right } })
end

---Открыть окно выбора MR (точка входа команды :Review без аргументов).
function M.review()
  require("review-gitlab.mr").open()
end

---Закрыть ревью: закрыть вкладку диффа и снять отрисовку (замечания сохраняются).
function M.close()
  vim.cmd("tabclose")
  hooks.on_session_closed()
  require("review-gitlab.marks").clear_all()
end

---Удалить все замечания текущей (repo, branch).
function M.clear()
  local n = store.count()
  store.clear()
  require("review-gitlab.marks").clear_all()
  vim.notify(n > 0 and ("Удалено замечаний: " .. n) or "Нет замечаний для удаления", vim.log.levels.INFO, { title = "review.gitlab" })
end

function M.toggle_readonly()
  local cfg = config.get()
  cfg.codediff.readonly = not cfg.codediff.readonly

  local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
  if not ok then
    return
  end

  local tabpage = hooks.get_current_tabpage()
  if not tabpage then
    return
  end

  local orig_buf, mod_buf = lifecycle.get_buffers(tabpage)
  for _, bufnr in ipairs({ orig_buf, mod_buf }) do
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_set_option_value("modifiable", not cfg.codediff.readonly, { buf = bufnr })
      vim.api.nvim_set_option_value("readonly", cfg.codediff.readonly, { buf = bufnr })
    end
  end

  keymaps.clear_keymaps()
  keymaps.setup_keymaps(tabpage)

  local mode = cfg.codediff.readonly and "readonly" or "редактирование"
  vim.notify("Режим: " .. mode, vim.log.levels.INFO, { title = "review.gitlab" })
end

---@param args string[]? аргументы команды (MR IID, --dry-run)
---@param client GlabClient? инъекция транспорта (для тестов)
function M.upload(args, client)
  require("review-gitlab.upload").upload(args or {}, client)
end

---Dry run: показать, что бы загрузилось, ничего не постя.
---@param args string[]?
---@param client GlabClient?
function M.check(args, client)
  require("review-gitlab.upload").upload({ "--dry-run", unpack(args or {}) }, client)
end

---Открыть файл лога в сплите (:Review log). `clear` — очистить лог.
---@param sub? string
function M.log(sub)
  local path = log.path()
  if not path then
    vim.notify("Логирование выключено (config.log = false)", vim.log.levels.WARN, { title = "review.gitlab" })
    return
  end
  if sub == "clear" then
    os.remove(path)
    vim.notify("Лог очищен: " .. path, vim.log.levels.INFO, { title = "review.gitlab" })
    return
  end
  vim.cmd("botright split " .. vim.fn.fnameescape(path))
end

return M
