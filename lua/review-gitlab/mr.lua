local M = {}

local storage = require("review-gitlab.storage")
local log = require("review-gitlab.log")

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "review.gitlab" })
end

---Плавающее окно со списком активных MR (из локального кэша); на <CR> — открыть.
---@param mrs table[] нормализованные MR (из storage.list_state)
local function show_picker(mrs)
  local lines = {}
  local width = 0
  for _, mr in ipairs(mrs) do
    local author = mr.author and (" @" .. mr.author) or ""
    local line = string.format("!%-5s %s → %s   %s%s",
      tostring(mr.iid), mr.source_branch or "?", mr.target_branch or "?", mr.title or "", author)
    table.insert(lines, line)
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"

  local height = math.min(#lines, 20)
  width = math.min(math.max(width + 2, 40), vim.o.columns - 4)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " Активные MR (CR — выбрать, q — закрыть) ",
    title_pos = "center",
  })
  vim.wo[win].cursorline = true

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local function select()
    local row = vim.api.nvim_win_get_cursor(win)[1]
    local mr = mrs[row]
    close()
    if mr then
      log.write(("mr picked: iid=%s %s"):format(tostring(mr.iid), tostring(mr.source_branch)))
      require("review-gitlab").open_mr(mr)
    end
  end

  local opts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set("n", "<CR>", select, opts)
  vim.keymap.set("n", "q", close, opts)
  vim.keymap.set("n", "<Esc>", close, opts)
end

---Офлайн: показать активные MR из локального кэша (active/). Сети не требует.
function M.pick_branch()
  local entries = storage.list_state("active")
  if #entries == 0 then
    return notify("Нет активных MR в кэше. Сначала выполните :CodeReview pull", vim.log.levels.WARN)
  end
  local mrs = {}
  for _, e in ipairs(entries) do
    mrs[#mrs + 1] = e.mr
  end
  table.sort(mrs, function(a, b)
    return (a.iid or 0) > (b.iid or 0)
  end)
  log.write(("mr.pick_branch: %d активных MR в кэше"):format(#mrs))
  show_picker(mrs)
end

return M
