local glab = require("review-gitlab.glab")
local storage = require("review-gitlab.storage")
local utils = require("review-gitlab.utils")
local log = require("review-gitlab.log")

local M = {}

local function notify(msg, level)
  log.write("notify: " .. msg)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "review.gitlab" })
end

---Привести объект MR из glab к тому, что хранит плагин.
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
    diff_refs = raw.diff_refs, -- есть в ответе одного MR, не в списке
    state = raw.state,
    updated_at = os.time(),
  }
end

---Онлайн-синхронизация локального кэша MR с GitLab:
--- обновляет/добавляет открытые MR в active/, переносит слитые в merged/ и
--- закрытые в cancelled/. Тянет только метаданные (коммиты — git fetch вручную).
---@param client GlabClient? инъекция транспорта (тесты)
function M.pull(client)
  local root = utils.git_root()
  if not root then
    return notify("Не git-репозиторий", vim.log.levels.ERROR)
  end
  client = client or glab.new(root)
  storage.migrate_flat()
  log.write("=== pull ===")

  client.paginate("projects/:id/merge_requests?state=opened&per_page=100", function(res)
    if not res.ok or type(res.body) ~= "table" then
      return notify("Не удалось получить список MR: " .. vim.trim(res.stderr or ""), vim.log.levels.ERROR)
    end

    local opened = {} -- iid -> true
    local order = {} -- iids в порядке получения детали
    for _, raw in ipairs(res.body) do
      if type(raw) == "table" and raw.iid and raw.source_branch then
        opened[raw.iid] = true
        order[#order + 1] = raw.iid
      end
    end
    log.write(("pull: %d открытых MR"):format(#order))

    local stats = { written = 0, merged = 0, cancelled = 0, failed = 0 }

    -- Шаг 2: деталь каждого открытого MR (ради diff_refs) -> active/
    local function reconcile_removed()
      -- Шаг 3: локальные active, которых больше нет среди открытых -> merged/cancelled
      local stale = {}
      for _, e in ipairs(storage.list_state("active")) do
        local iid = e.mr and e.mr.iid
        if iid and not opened[iid] then
          stale[#stale + 1] = e
        end
      end

      local j = 0
      local function step_stale()
        j = j + 1
        local e = stale[j]
        if not e then
          notify(string.format(
            "pull: активных %d, в merged %d, в cancelled %d%s",
            stats.written, stats.merged, stats.cancelled,
            stats.failed > 0 and (", ошибок " .. stats.failed) or ""))
          return
        end
        client.get("projects/:id/merge_requests/" .. e.mr.iid, function(r)
          if r.ok and r.body then
            if r.body.state == "merged" then
              storage.move_mr(e.branch, "active", "merged")
              stats.merged = stats.merged + 1
            elseif r.body.state == "closed" then
              storage.move_mr(e.branch, "active", "cancelled")
              stats.cancelled = stats.cancelled + 1
            end
          end
          step_stale()
        end)
      end
      step_stale()
    end

    local i = 0
    local function step_opened()
      i = i + 1
      local iid = order[i]
      if not iid then
        return reconcile_removed()
      end
      client.get("projects/:id/merge_requests/" .. iid, function(r)
        if r.ok and r.body and r.body.diff_refs then
          storage.write_mr("active", normalize(r.body))
          stats.written = stats.written + 1
        else
          stats.failed = stats.failed + 1
          log.write(("pull: не удалось получить MR !%s: %s"):format(tostring(iid), vim.trim(r.stderr or "нет diff_refs")))
        end
        step_opened()
      end)
    end
    step_opened()
  end)
end

return M
