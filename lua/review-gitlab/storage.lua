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

---The per-(repo, branch) directory comments and MR metadata live in:
---`stdpath("data")/review/<repo>/<branch>/`. nil outside a git repo or when
---the branch cannot be determined (detached HEAD).
---@return string|nil
function M.review_dir()
  local root = get_git_root()
  local branch = M.git_branch()
  if not root or not branch then
    return nil
  end
  local repo = vim.fn.fnamemodify(root, ":t")
  local dir = string.format("%s/%s/%s", data_dir, repo, safe_branch(branch))
  return dir
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
---`:Review upload` knows which MR to post to without asking again.
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
