local config = require("review-gitlab.config")

local M = {}

---@return string|nil path resolved log file, nil when logging is disabled
local function logpath()
  local p = config.get().log
  if p == true then
    return vim.fn.stdpath("state") .. "/review-gitlab.log"
  end
  if type(p) == "string" and p ~= "" then
    return vim.fn.expand(p)
  end
  return nil
end
M.path = logpath

---Append a timestamped line, and an optional indented detail block, to the log.
---Silently does nothing when logging is disabled.
---@param msg string
---@param detail? string multi-line payload, printed indented
function M.write(msg, detail)
  local path = logpath()
  if not path then
    return
  end
  local f = io.open(path, "a")
  if not f then
    return
  end
  f:write(os.date("%Y-%m-%d %H:%M:%S") .. "  " .. msg .. "\n")
  if detail and detail ~= "" then
    for line in (detail .. "\n"):gmatch("(.-)\n") do
      f:write("    " .. line .. "\n")
    end
  end
  f:close()
end

---Как M.write, но пишет только при log_level = "debug" (payload'ы, тексты).
---@param msg string
---@param detail? string
function M.debug(msg, detail)
  if config.get().log_level == "debug" then
    M.write(msg, detail)
  end
end

return M
