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
---@return string каталог репозитория: stdpath(data)/review/<repo>
local function repo_dir(root)
  return string.format("%s/%s", data_dir, vim.fn.fnamemodify(root, ":t"))
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
  return string.format("%s/%s", repo_dir(root), safe_branch(branch))
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

---@param path string
---@param data table
local function write_json(path, data)
  pcall(vim.fn.mkdir, vim.fn.fnamemodify(path, ":h"), "p")
  local file = io.open(path, "w")
  if file then
    file:write(vim.fn.json_encode(data))
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

---Persist the selected MR's metadata (iid, diff_refs, branches) so a later
---`:CodeReview upload` knows which MR to post to without asking again.
---@param mr table
function M.save_mr(mr)
  local path = M.mr_path()
  if path then
    log.write("storage.save_mr -> " .. path, "iid=" .. tostring(mr.iid))
    write_json(path, mr)
  end
end

---@return table|nil
function M.load_mr()
  local path = M.mr_path()
  local mr = path and read_json(path) or nil
  log.write(("storage.load_mr <- %s"):format(mr and ("iid=" .. tostring(mr.iid)) or "none"))
  return mr
end

return M
