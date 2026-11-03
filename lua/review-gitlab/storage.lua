local M = {}

local log = require("review-gitlab.log")

local data_dir = vim.fn.stdpath("data") .. "/review"

---@return string|nil
local function get_git_root()
  return require("review-gitlab.utils").git_root()
end

---@return string|nil
function M.git_branch()
  local result = vim.fn.systemlist({ "git", "rev-parse", "--abbrev-ref", "HEAD" })
  if vim.v.shell_error ~= 0 or not result[1] or result[1] == "" or result[1] == "HEAD" then
    return nil
  end
  return result[1]
end

---Filesystem-safe form of a branch name (slashes etc. are not valid dirs).
---@param branch string
---@return string
local function safe_branch(branch)
  return (branch:gsub("[^%w%-_]", "_"))
end

---@param root string
---@return string каталог проекта: stdpath(data)/review/<project>
local function repo_dir(root)
  return string.format("%s/%s", data_dir, vim.fn.fnamemodify(root, ":t"))
end

---Состояния MR = подпапки проекта.
local STATES = { active = true, merged = true, cancelled = true }

---@param root string
---@param state string active|merged|cancelled
---@return string каталог состояния: <project>/<state>
local function state_dir(root, state)
  return string.format("%s/%s", repo_dir(root), state)
end

---@param root string
---@param state string
---@param branch string
---@return string каталог MR: <project>/<state>/<branch>
local function mr_dir(root, state, branch)
  return string.format("%s/%s", state_dir(root, state), safe_branch(branch))
end

---@param root string
---@return string путь указателя активной ветки ревью
local function active_pointer(root)
  return repo_dir(root) .. "/.active"
end

---Ветка, против которой идёт ревью (source-ветка MR) — ключ каталога хранения,
---а НЕ текущий git HEAD (можно ревьюить, находясь на другой ветке).
---@type string|nil
local active_branch = nil

---@param root string
---@return string|nil
local function read_active(root)
  local f = io.open(active_pointer(root), "r")
  if not f then
    return nil
  end
  local b = f:read("*a")
  f:close()
  b = b and vim.trim(b)
  return (b and b ~= "") and b or nil
end

---Задать активную ветку ревью (вызывается при открытии MR). Сохраняется в
---указатель, чтобы `:CodeReview upload` в следующей сессии нашёл те же замечания.
---@param branch string|nil
function M.set_active_branch(branch)
  active_branch = branch
  local root = get_git_root()
  if root and branch then
    pcall(vim.fn.mkdir, repo_dir(root), "p")
    local f = io.open(active_pointer(root), "w")
    if f then
      f:write(branch)
      f:close()
    end
  end
  log.write("storage.set_active_branch: " .. tostring(branch))
end

---Каталог замечаний и метаданных MR: `stdpath(data)/review/<repo>/<branch>/`,
---где <branch> — активная ветка ревью (или указатель, или git HEAD как запасной).
---nil вне git-репозитория или когда ветку определить нельзя.
---@return string|nil
function M.review_dir()
  local root = get_git_root()
  if not root then
    return nil
  end
  local branch = active_branch or read_active(root) or M.git_branch()
  if not branch then
    return nil
  end
  -- Рабочие замечания всегда в active/<branch>/
  return mr_dir(root, "active", branch)
end

---@return string|nil
function M.get_storage_path()
  local dir = M.review_dir()
  return dir and (dir .. "/comments.json")
end

---@return string|nil
function M.mr_path()
  local dir = M.review_dir()
  return dir and (dir .. "/mr.json")
end

local is_list = vim.islist or vim.tbl_islist

---Отформатированный (с отступами) JSON. Скаляры кодируем через vim.json.encode
---ради корректного экранирования; таблицы разворачиваем сами. Ключи объектов
---сортируем для стабильного вывода.
---@param value any
---@param indent number
---@return string
local function pretty(value, indent)
  if type(value) ~= "table" then
    return vim.json.encode(value)
  end
  if vim.tbl_isempty(value) then
    return is_list(value) and "[]" or "{}"
  end
  local pad, pad2 = string.rep("  ", indent), string.rep("  ", indent + 1)
  local parts = {}
  if is_list(value) then
    for _, v in ipairs(value) do
      parts[#parts + 1] = pad2 .. pretty(v, indent + 1)
    end
    return "[\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "]"
  end
  local keys = {}
  for k in pairs(value) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  for _, k in ipairs(keys) do
    parts[#parts + 1] = pad2 .. vim.json.encode(tostring(k)) .. ": " .. pretty(value[k], indent + 1)
  end
  return "{\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "}"
end

---@param path string
---@param data table
local function write_json(path, data)
  pcall(vim.fn.mkdir, vim.fn.fnamemodify(path, ":h"), "p")
  local file = io.open(path, "w")
  if file then
    file:write(pretty(data, 0) .. "\n")
    file:close()
  end
end

---@param path string
---@return table|nil
local function read_json(path)
  local file = io.open(path, "r")
  if not file then
    return nil
  end
  local content = file:read("*a")
  file:close()
  if content and content ~= "" then
    local ok, data = pcall(vim.fn.json_decode, content)
    if ok and type(data) == "table" then
      return data
    end
  end
  return nil
end

---@param comments table
function M.save(comments)
  local path = M.get_storage_path()
  if path then
    log.write("storage.save -> " .. path)
    write_json(path, comments)
  end
end

---@return table
function M.load()
  local path = M.get_storage_path()
  if not path then
    log.write("storage.load: no review dir (not a git repo or detached HEAD)")
    return {}
  end
  local data = read_json(path)
  log.write(("storage.load <- %s (%s)"):format(path, data and "found" or "empty"))
  return data or {}
end

function M.clear()
  local path = M.get_storage_path()
  if path then
    os.remove(path)
  end
end

---Записать метаданные MR в <state>/<source_branch>/mr.json. Ключ — source-ветка
---из самого MR (не из указателя), поэтому годится для pull по многим MR.
---@param state string active|merged|cancelled
---@param mr table
function M.write_mr(state, mr)
  local root = get_git_root()
  if not root or not mr.source_branch then
    return
  end
  local path = mr_dir(root, state, mr.source_branch) .. "/mr.json"
  log.write(("storage.write_mr[%s] -> %s"):format(state, path), "iid=" .. tostring(mr.iid))
  write_json(path, mr)
end

---Сохранить метаданные выбранного MR в active/ (для :CodeReview upload/approve).
---@param mr table
function M.save_mr(mr)
  M.write_mr("active", mr)
end

---@return table|nil метаданные MR активной ветки
function M.load_mr()
  local path = M.mr_path()
  local mr = path and read_json(path) or nil
  log.write(("storage.load_mr <- %s"):format(mr and ("iid=" .. tostring(mr.iid)) or "none"))
  return mr
end

---Список MR в состоянии: { { branch = <dir>, mr = <mr.json> } }.
---@param state string active|merged|cancelled
---@return { branch: string, mr: table }[]
function M.list_state(state)
  local root = get_git_root()
  if not root then
    return {}
  end
  local dir = state_dir(root, state)
  if vim.fn.isdirectory(dir) == 0 then
    return {}
  end
  local out = {}
  for name, t in vim.fs.dir(dir) do
    if t == "directory" then
      local mr = read_json(dir .. "/" .. name .. "/mr.json")
      if mr then
        out[#out + 1] = { branch = name, mr = mr }
      end
    end
  end
  return out
end

---Переместить каталог MR между состояниями (вместе с comments.json).
---@param branch string
---@param from_state string
---@param to_state string
---@return boolean
function M.move_mr(branch, from_state, to_state)
  local root = get_git_root()
  if not root then
    return false
  end
  local src = mr_dir(root, from_state, branch)
  if vim.fn.isdirectory(src) == 0 then
    return false
  end
  local dst = mr_dir(root, to_state, branch)
  if vim.fn.isdirectory(dst) == 1 then
    vim.fn.delete(dst, "rf")
  end
  pcall(vim.fn.mkdir, state_dir(root, to_state), "p")
  local ok = os.rename(src, dst)
  log.write(("storage.move_mr %s: %s -> %s (%s)"):format(branch, from_state, to_state, tostring(ok)))
  return ok and true or false
end

---Одноразовая миграция старой плоской схемы `<project>/<branch>/` в `active/`.
function M.migrate_flat()
  local root = get_git_root()
  if not root then
    return
  end
  local proj = repo_dir(root)
  if vim.fn.isdirectory(proj) == 0 then
    return
  end
  for name, t in vim.fs.dir(proj) do
    if t == "directory" and not STATES[name] then
      local src = proj .. "/" .. name
      local dst = state_dir(root, "active") .. "/" .. name
      if vim.fn.isdirectory(dst) == 0 then
        pcall(vim.fn.mkdir, state_dir(root, "active"), "p")
        os.rename(src, dst)
        log.write("storage.migrate_flat: " .. name .. " -> active/")
      end
    end
  end
end

return M
