local M = {}

---@class ReviewGitlabConfig
---@field dry_run boolean предпросмотр загрузки без постинга (по умолчанию false)
---@field marker string скрытый HTML-маркер, связывающий заметку с id замечания
---@field require_matching_head boolean пропускать замечания, чья head-ревизия ≠ head MR (по умолчанию true)
---@field glab string исполняемый файл glab
---@field timeout number таймаут запроса, мс
---@field log boolean|string лог: true -> stdpath state, путь-строка, или false чтобы выключить
---@field log_level "info"|"debug" уровень лога; debug добавляет payload'ы/тексты
---@field codediff { readonly: boolean }
---@field keymaps table<string, string|false>

---@type ReviewGitlabConfig
M.defaults = {
  dry_run = false,
  marker = "review.gitlab",
  require_matching_head = true,
  glab = "glab",
  timeout = 30000,
  log = true,
  log_level = "debug",
  codediff = {
    readonly = true,
  },
  keymaps = {
    -- Режим редактирования (leader)
    add_comment = "<localleader>cc",
    add_file_comment = "<localleader>cf",
    edit_comment = "<localleader>ce",
    delete_comment = "<localleader>cd",
    -- Режим readonly (простые клавиши)
    readonly_add = "i",
    readonly_edit = "e",
    readonly_delete = "d",
    readonly_add_file = "F",
    -- Навигация
    next_comment = "]n",
    prev_comment = "[n",
    next_file = "<Tab>",
    prev_file = "<S-Tab>",
    toggle_file_panel = "f",
    -- Действия
    list_comments = "c",
    upload = "u",
    approve = "A",
    clear_comments = "<C-r>",
    close = "q",
    toggle_readonly = "R",
    show_help = "?",
    -- Окно комментария
    popup_submit = "<C-s>",
    popup_cancel = "q",
  },
}

---@type ReviewGitlabConfig
M.options = vim.deepcopy(M.defaults)

---@param opts? ReviewGitlabConfig
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

---@return ReviewGitlabConfig
function M.get()
  return M.options
end

return M
