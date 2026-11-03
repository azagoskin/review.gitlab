local M = {}

local glab = require("review-gitlab.glab")
local utils = require("review-gitlab.utils")
local log = require("review-gitlab.log")

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "review.gitlab" })
end

---Нормализовать объект MR из ответа glab к тому, что нужно плагину.
---@param raw table
---@return table
local function normalize(raw)
  return {
    iid = raw.iid,
    title = raw.title,
    source_branch = raw.source_branch,
    target_branch = raw.target_branch,
    web_url = raw.web_url,
    author = raw.author and raw.author.username or nil,
    diff_refs = raw.diff_refs, -- присутствует в ответе одного MR, не в списке
  }
end

---Запросить у GitLab подробности MR (ради diff_refs) и открыть дифф.
---@param client GlabClient
---@param mr table
local function open_selected(client, mr)
  client.get("projects/:id/merge_requests/" .. mr.iid, function(res)
    if not res.ok or not res.body or not res.body.diff_refs then
      return notify("Не удалось получить MR !" .. mr.iid .. ": " .. vim.trim(res.stderr or "нет diff_refs"), vim.log.levels.ERROR)
    end
    local full = normalize(res.body)
    full.selected_at = os.time()
    log.write(("mr selected: iid=%s %s -> %s"):format(tostring(full.iid), tostring(full.source_branch), tostring(full.target_branch)))
    require("review-gitlab").open_mr(full)
  end)
end

---Построить плавающее окно со списком MR; на <CR> — выбрать.
---@param client GlabClient
---@param mrs table[]
local function show_picker(client, mrs)
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
    title = " Открытые MR (CR — выбрать, q — закрыть) ",
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
      open_selected(client, mr)
    end
  end

  local opts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set("n", "<CR>", select, opts)
  vim.keymap.set("n", "q", close, opts)
  vim.keymap.set("n", "<Esc>", close, opts)
end

---Точка входа: получить открытые MR и показать список.
function M.open()
  local root = utils.git_root()
  if not root then
    return notify("Не git-репозиторий", vim.log.levels.ERROR)
  end
  local client = glab.new(root)
  log.write("mr.open: fetching open merge requests")
  client.paginate("projects/:id/merge_requests?state=opened&per_page=100", function(res)
    if not res.ok or type(res.body) ~= "table" then
      return notify("Не удалось получить список MR: " .. vim.trim(res.stderr or ""), vim.log.levels.ERROR)
    end
    local mrs = {}
    for _, raw in ipairs(res.body) do
      if type(raw) == "table" and raw.iid then
        table.insert(mrs, normalize(raw))
      end
    end
    log.write(("mr.open: %d open MR(s)"):format(#mrs))
    if #mrs == 0 then
      return notify("Нет открытых MR", vim.log.levels.WARN)
    end
    table.sort(mrs, function(a, b)
      return (a.iid or 0) > (b.iid or 0)
    end)
    show_picker(client, mrs)
  end)
end

return M
