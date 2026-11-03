if vim.g.loaded_review_gitlab then
  return
end
vim.g.loaded_review_gitlab = true

local subcommands = {
  upload = {
    fn = function(args) require("review-gitlab").upload(args) end,
    desc = "Загрузить замечания в MR (опц.: IID)",
  },
  check = {
    fn = function(args) require("review-gitlab").check(args) end,
    desc = "Предпросмотр: что будет загружено, без постинга",
  },
  note = {
    fn = function(_, opts)
      local comments = require("review-gitlab.comments")
      if opts.range > 0 then
        comments.add_for_range(opts.line1, opts.line2)
      else
        comments.add_at_cursor()
      end
    end,
    desc = "Добавить замечание на строке (или :'<,'>Review note на диапазон)",
  },
  edit = { fn = function() require("review-gitlab.comments").edit_at_cursor() end, desc = "Редактировать замечание под курсором" },
  delete = { fn = function() require("review-gitlab.comments").delete_at_cursor() end, desc = "Удалить замечание под курсором" },
  list = { fn = function() require("review-gitlab.comments").list() end, desc = "Список всех замечаний" },
  close = { fn = function() require("review-gitlab").close() end, desc = "Закрыть ревью" },
  clear = { fn = function() require("review-gitlab").clear() end, desc = "Удалить все замечания" },
  log = { fn = function(args) require("review-gitlab").log(args[1]) end, desc = "Открыть лог (log clear — очистить)" },
}

local subcommand_names = vim.tbl_keys(subcommands)

vim.api.nvim_create_user_command("Review", function(opts)
  local cmd = opts.fargs[1]

  -- Без подкоманды: открыть список MR
  if not cmd or cmd == "" then
    require("review-gitlab").review()
    return
  end

  local subcmd = subcommands[cmd]
  if subcmd then
    subcmd.fn({ unpack(opts.fargs, 2) }, opts)
  else
    vim.notify(
      "Неизвестная подкоманда: " .. cmd .. "\nДоступно: " .. table.concat(subcommand_names, ", "),
      vim.log.levels.ERROR,
      { title = "review.gitlab" }
    )
  end
end, {
  nargs = "*",
  range = true,
  complete = function(arg_lead, cmd_line)
    local parts = vim.split(cmd_line, "%s+", { trimempty = true })
    if #parts <= 2 then
      return vim.tbl_filter(function(c)
        return c:find(arg_lead, 1, true) == 1
      end, subcommand_names)
    end
    return {}
  end,
  desc = "Код-ревью MR GitLab",
})
