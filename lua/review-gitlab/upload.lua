local config = require("review-gitlab.config")
local glab = require("review-gitlab.glab")
local diff = require("review-gitlab.diff")
local position = require("review-gitlab.position")
local storage = require("review-gitlab.storage")
local log = require("review-gitlab.log")

local M = {}

local function notify(msg, level)
  log.write("notify: " .. msg)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "review-gitlab" })
end

---@param args string[]
---@return { dry_run: boolean, iid: number?, error: string? }
local function parse_args(args)
  local out = { dry_run = config.get().dry_run }
  for _, a in ipairs(args or {}) do
    if a == "--dry-run" then
      out.dry_run = true
    elseif a == "--no-dry-run" then
      out.dry_run = false
    elseif a:match("^%d+$") then
      out.iid = tonumber(a)
    else
      out.error = "unknown argument: " .. a
    end
  end
  return out
end

---The branch the comments were reviewed against, taken from their head_ref
---(not the currently checked-out branch, which may differ). "WORKING" and
---missing refs are ignored. Errors if comments span more than one branch.
---@param comments Comment[]
---@return string? branch, string? err
function M.review_branch(comments)
  local set = {}
  for _, c in ipairs(comments) do
    local hr = c.revisions and c.revisions.head_ref
    if hr and hr ~= "WORKING" then
      set[hr] = true
    end
  end
  local names = vim.tbl_keys(set)
  table.sort(names)
  if #names == 0 then
    return nil, nil
  end
  if #names > 1 then
    return nil, "замечания относятся к нескольким ревью-веткам (" .. table.concat(names, ", ") .. ") — укажите IID MR: :CodeReview upload <iid>"
  end
  return names[1], nil
end

---@param seed string directory to resolve the repo from
---@return string? root, string? branch
local function git_context(seed)
  local root = vim.trim(vim.fn.system({ "git", "-C", seed, "rev-parse", "--show-toplevel" }))
  if vim.v.shell_error ~= 0 or root == "" then
    return nil, nil
  end
  local branch = vim.trim(vim.fn.system({ "git", "-C", root, "rev-parse", "--abbrev-ref", "HEAD" }))
  return root, (branch ~= "" and branch ~= "HEAD") and branch or nil
end

---Decide what to do with each comment. Pure: no network, no side effects.
---@param comments Comment[]
---@param ctx { diff_index: table<string, FileDiff>, diff_refs: table, existing_ids: table<string, boolean> }
---@param cfg ReviewGitlabConfig
---@return { comment: Comment, kind: "inline"|"note"|"skip", body: string?, position: table?, reason: string? }[]
function M.plan(comments, ctx, cfg)
  local actions = {}
  for _, comment in ipairs(comments) do
    local action = { comment = comment }
    if comment.uploaded then
      action.kind, action.reason = "skip", "уже загружено (локальная отметка)"
    elseif ctx.existing_ids[comment.id] then
      action.kind, action.reason = "skip", "уже загружено (маркер в MR)"
    elseif comment.line == 0 then
      action.kind, action.body = "note", position.build_body(cfg, comment)
    else
      local revs = comment.revisions
      local fd = ctx.diff_index[comment.file]
      if not revs or not revs.head_sha then
        action.kind, action.reason = "skip", "no committed revision (review a commit, not the working tree)"
      elseif cfg.require_matching_head and revs.head_sha ~= ctx.diff_refs.head_sha then
        action.kind, action.reason = "skip", "made against a different revision than the MR head"
      elseif not fd then
        action.kind, action.reason = "skip", "file not part of the MR diff"
      else
        local pos, err = position.build_position(comment, fd, ctx.diff_refs)
        if pos then
          action.kind, action.position, action.body = "inline", pos, position.build_body(cfg, comment)
        else
          action.kind, action.reason = "skip", err
        end
      end
    end
    table.insert(actions, action)
  end
  return actions
end

---@param comment Comment
---@return string
local function location(comment)
  if comment.line == 0 then
    return comment.file
  end
  local tilde = (comment.side == "old") and "~" or ""
  if comment.line_end and comment.line_end ~= comment.line then
    return string.format("%s:%s%d-%s%d", comment.file, tilde, comment.line, tilde, comment.line_end)
  end
  return string.format("%s:%s%d", comment.file, tilde, comment.line)
end

---@param actions table[]
---@param dry_run boolean
local function summary_lines(actions, dry_run)
  local verb = dry_run and "Будет загружено" or "Загружено"
  local lines = {}
  local posted, noted, skipped = {}, {}, {}
  for _, a in ipairs(actions) do
    if a.kind == "inline" then
      table.insert(posted, "  • " .. location(a.comment))
    elseif a.kind == "note" then
      table.insert(noted, "  • " .. location(a.comment) .. " (комментарий к файлу)")
    else
      table.insert(skipped, string.format("  • %s — %s", location(a.comment), a.reason or "пропущено"))
    end
  end
  table.insert(lines, string.format("# review.gitlab → GitLab (%s)", dry_run and "предпросмотр" or "загрузка"))
  table.insert(lines, "")
  table.insert(lines, string.format("%s: inline %d, к файлу %d, пропущено %d", verb, #posted, #noted, #skipped))
  for _, group in ipairs({ { "Inline", posted }, { "К файлу", noted }, { "Пропущено", skipped } }) do
    if #group[2] > 0 then
      table.insert(lines, "")
      table.insert(lines, "## " .. group[1])
      vim.list_extend(lines, group[2])
    end
  end
  return lines
end

---@param lines string[]
local function show_report(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  local height = math.min(#lines + 1, 20)
  vim.cmd("botright " .. height .. "split")
  vim.api.nvim_win_set_buf(0, buf)
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, nowait = true })
end

---Post each inline/note action in order, then report. Recursion keeps the
---requests sequential so a failure is attributed to the right comment.
---@param client GlabClient
---@param base string endpoint prefix ".../merge_requests/<iid>"
---@param actions table[]
local function post_all(client, base, actions)
  local i, errors, done = 0, {}, 0
  local function step()
    i = i + 1
    local a = actions[i]
    if not a then
      local msg = string.format("Загружено замечаний в MR: %d", done)
      if #errors > 0 then
        msg = msg .. string.format(", с ошибкой: %d:\n%s", #errors, table.concat(errors, "\n"))
      end
      notify(msg, #errors > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
      show_report(summary_lines(actions, false))
      -- Перерисовать: загруженные замечания отмечаются ✓
      pcall(function()
        require("review-gitlab.marks").refresh()
      end)
      return
    end
    if a.kind ~= "inline" and a.kind ~= "note" then
      return step()
    end
    local payload = { body = a.body }
    if a.position then
      payload.position = a.position
    end
    client.post(base .. "/discussions", payload, function(res)
      if res.ok then
        done = done + 1
        local did = res.body and res.body.id and tostring(res.body.id) or nil
        require("review-gitlab.store").mark_uploaded(a.comment.id, did)
      else
        table.insert(errors, string.format("  • %s — %s", location(a.comment), vim.trim(res.stderr or "запрос не удался")))
      end
      step()
    end)
  end
  step()
end

---Fetch MR refs, diffs and existing discussions, then plan and (unless dry-run) post.
---@param client GlabClient
---@param iid number
---@param comments Comment[]
---@param opts { dry_run: boolean }
local function run(client, iid, comments, opts)
  local base = "projects/:id/merge_requests/" .. iid
  client.get(base, function(mr)
    if not mr.ok or not mr.body or not mr.body.diff_refs then
      return notify("Не удалось прочитать MR !" .. iid .. ": " .. vim.trim(mr.stderr or "нет diff_refs"), vim.log.levels.ERROR)
    end
    local diff_refs = mr.body.diff_refs
    client.paginate(base .. "/diffs", function(diffs)
      if not diffs.ok then
        return notify("Не удалось прочитать дифф MR: " .. vim.trim(diffs.stderr or ""), vim.log.levels.ERROR)
      end
      client.paginate(base .. "/discussions", function(disc)
        local existing = ""
        if disc.ok and disc.body then
          existing = vim.json.encode(disc.body)
        end
        local ctx = {
          diff_index = diff.index(diffs.body),
          diff_refs = diff_refs,
          existing_ids = position.extract_ids(existing, config.get()),
        }
        local actions = M.plan(comments, ctx, config.get())
        log.write("plan computed", table.concat(summary_lines(actions, opts.dry_run), "\n"))
        if opts.dry_run then
          show_report(summary_lines(actions, true))
          return
        end
        post_all(client, base, actions)
      end)
    end)
  end)
end

---Entry point for `:CodeReview upload`.
---@param args string[] command arguments (MR IID, --dry-run)
---@param client GlabClient? injected transport (tests); a real glab client otherwise
function M.upload(args, client)
  local parsed = parse_args(args)
  log.write("=== upload ===", "args=" .. vim.inspect(args) .. "  parsed=" .. vim.inspect(parsed))
  if parsed.error then
    return notify(parsed.error, vim.log.levels.ERROR)
  end

  local store = require("review-gitlab.store")
  store.load()
  local comments = store.get_all()
  log.write(("store: %d comment(s)"):format(#comments))
  if #comments == 0 then
    return notify("Нет замечаний для загрузки", vim.log.levels.WARN)
  end

  local root, branch = git_context(vim.fn.getcwd())
  log.write(("git: root=%s  branch=%s"):format(tostring(root), tostring(branch)))
  if not root then
    return notify("Не git-репозиторий", vim.log.levels.ERROR)
  end
  client = client or glab.new(root)

  if parsed.iid then
    return run(client, parsed.iid, comments, parsed)
  end

  -- Приоритет: IID выбранного MR из mr.json (записан при :CodeReview)
  local mr = storage.load_mr()
  if mr and mr.iid then
    log.write("upload: IID из mr.json = " .. tostring(mr.iid))
    return run(client, mr.iid, comments, parsed)
  end

  -- No IID: target the MR of the branch the comments were reviewed against,
  -- falling back to the checked-out branch when the comments carry no ref.
  local review, rb_err = M.review_branch(comments)
  if rb_err then
    return notify(rb_err, vim.log.levels.ERROR)
  end
  local target = review or branch
  log.write(("target branch: %s (from %s)"):format(tostring(target), review and "comment head_ref" or "git HEAD"))
  if not target then
    return notify("Нет review-ветки на замечаниях и detached HEAD: укажите IID (:CodeReview upload <iid>)", vim.log.levels.ERROR)
  end
  local query = string.format("projects/:id/merge_requests?state=opened&source_branch=%s", vim.uri_encode(target))
  client.get(query, function(res)
    if not res.ok or type(res.body) ~= "table" or not res.body[1] then
      return notify("Нет открытого MR для ветки '" .. target .. "'. Укажите IID: :CodeReview upload <iid>", vim.log.levels.ERROR)
    end
    run(client, res.body[1].iid, comments, parsed)
  end)
end

---Поставить апрув на MR: POST .../merge_requests/<iid>/approve. IID — из
---аргумента или из mr.json выбранного MR.
---@param args string[]? аргументы команды (IID)
---@param client GlabClient? инъекция транспорта (тесты)
function M.approve(args, client)
  local parsed = parse_args(args or {})
  log.write("=== approve ===", "args=" .. vim.inspect(args) .. "  parsed=" .. vim.inspect(parsed))
  if parsed.error then
    return notify(parsed.error, vim.log.levels.ERROR)
  end

  local root = git_context(vim.fn.getcwd())
  if not root then
    return notify("Не git-репозиторий", vim.log.levels.ERROR)
  end
  client = client or glab.new(root)

  local iid = parsed.iid
  if not iid then
    local mr = storage.load_mr()
    iid = mr and mr.iid
  end
  if not iid then
    return notify("Не выбран MR. Откройте его (:CodeReview) или укажите IID: :CodeReview approve <iid>", vim.log.levels.ERROR)
  end

  local endpoint = "projects/:id/merge_requests/" .. iid .. "/approve"
  client.post(endpoint, vim.empty_dict(), function(res)
    if res.ok then
      notify("MR !" .. iid .. " заапрувлен", vim.log.levels.INFO)
    else
      notify("Не удалось заапрувить MR !" .. iid .. ": " .. vim.trim(res.stderr or "запрос не удался"), vim.log.levels.ERROR)
    end
  end)
end

return M
