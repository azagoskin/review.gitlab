local config = require("review-gitlab.config")
local log = require("review-gitlab.log")

local M = {}

---@param s string?
---@param max number
---@return string
local function truncate(s, max)
  s = s or ""
  return #s > max and (s:sub(1, max) .. "…(" .. #s .. "B)") or s
end

---Parse newline-delimited JSON (`glab api --output ndjson`): one array element
---per line. Needed because `--paginate` concatenates a JSON array per page
---(`[...][...]`), which a plain json.decode cannot read; ndjson merges cleanly.
---@param stdout string?
---@return boolean ok, table|string elements or an error message
local function parse_ndjson(stdout)
  local arr = {}
  for line in (stdout or ""):gmatch("[^\n]+") do
    if line:match("%S") then
      local ok, decoded = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
      if not ok then
        return false, tostring(decoded)
      end
      arr[#arr + 1] = decoded
    end
  end
  return true, arr
end
M._parse_ndjson = parse_ndjson

---@class GlabResult
---@field ok boolean
---@field status number? exit code
---@field body any decoded JSON on success
---@field stderr string?

---A thin async wrapper over the `glab api` CLI. One client is bound to a repo
---directory so glab resolves the host, project (:id) and auth from its remote.
---@class GlabClient
---@field get fun(endpoint: string, cb: fun(res: GlabResult))
---@field paginate fun(endpoint: string, cb: fun(res: GlabResult))
---@field post fun(endpoint: string, payload: table, cb: fun(res: GlabResult))

---@param cwd string repo directory glab runs in
---@param args string[] arguments after `glab`
---@param stdin string? request body for --input -
---@param cb fun(res: GlabResult)
---@param ndjson boolean parse stdout as newline-delimited JSON (paginated arrays)
local function run(cwd, args, stdin, ndjson, cb)
  local cfg = config.get()
  log.write(("$ %s %s  (cwd=%s)"):format(cfg.glab, table.concat(args, " "), cwd), stdin and ("stdin: " .. stdin) or nil)
  local ok, err = pcall(vim.system, { cfg.glab, unpack(args) }, {
    cwd = cwd,
    text = true,
    stdin = stdin,
    timeout = cfg.timeout,
  }, function(out)
    log.write(
      ("-> exit=%s  stdout=%dB  stderr=%s"):format(tostring(out.code), #(out.stdout or ""), vim.trim(out.stderr or "")),
      (out.code ~= 0 or (out.stdout or "") == "") and truncate(out.stdout, 2000) or nil
    )
    local res = { status = out.code, stderr = out.stderr }
    if out.code ~= 0 then
      res.ok = false
    elseif ndjson then
      local decoded_ok, decoded = parse_ndjson(out.stdout)
      res.ok = decoded_ok
      res.body = decoded_ok and decoded or nil
      if not decoded_ok then
        res.stderr = "failed to decode glab ndjson output: " .. tostring(decoded)
      end
    else
      local decoded_ok, decoded = pcall(vim.json.decode, out.stdout or "", { luanil = { object = true, array = true } })
      res.ok = decoded_ok
      res.body = decoded_ok and decoded or nil
      if not decoded_ok then
        res.stderr = "failed to decode glab output: " .. tostring(decoded)
      end
    end
    vim.schedule(function()
      cb(res)
    end)
  end)
  if not ok then
    log.write("!! could not launch " .. cfg.glab .. ": " .. tostring(err))
    vim.schedule(function()
      cb({ ok = false, stderr = "could not launch " .. cfg.glab .. ": " .. tostring(err) })
    end)
  end
end

---@param cwd string
---@return GlabClient
function M.new(cwd)
  return {
    get = function(endpoint, cb)
      run(cwd, { "api", endpoint }, nil, false, cb)
    end,
    paginate = function(endpoint, cb)
      -- ndjson so multi-page array responses stay parseable (see parse_ndjson).
      run(cwd, { "api", "--paginate", "--output", "ndjson", endpoint }, nil, true, cb)
    end,
    post = function(endpoint, payload, cb)
      -- --input sends a raw body but sets no Content-Type; GitLab rejects it
      -- with HTTP 415 unless we declare JSON explicitly.
      run(cwd, {
        "api",
        "--method",
        "POST",
        "--header",
        "Content-Type: application/json",
        "--input",
        "-",
        endpoint,
      }, vim.json.encode(payload), false, cb)
    end,
  }
end

return M
