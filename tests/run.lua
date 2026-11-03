-- Standalone test runner: `nvim --headless -l tests/run.lua` (or `make test`).
-- No external deps; a tiny assert harness over the pure modules plus one
-- end-to-end pass through upload.upload with a fake glab client.

package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local passed, failed = 0, 0
local function check(cond, name)
  if cond then
    passed = passed + 1
  else
    failed = failed + 1
    io.write("  FAIL: " .. name .. "\n")
  end
end
local function eq(a, b, name)
  check(vim.deep_equal(a, b), name .. " (got " .. vim.inspect(a) .. ")")
end

local diff = require("review-gitlab.diff")
local position = require("review-gitlab.position")
local upload = require("review-gitlab.upload")
local config = require("review-gitlab.config")
config.setup({ log = false }) -- keep tests from writing the diagnostic log
local cfg = config.get()

-- A small MR diff: line 1 context, line 2 removed, lines 2-3 (new) added.
local DIFF = table.concat({
  "@@ -1,3 +1,4 @@",
  " local M = {}",
  "-local old = 1",
  "+local new = 1",
  "+local extra = 2",
  " return M",
}, "\n")

do -- diff.parse_file
  local fd = diff.parse_file("m.lua", "m.lua", DIFF)
  eq(fd.by_new[1], { kind = "context", old_line = 1, new_line = 1 }, "parse: new line 1 is context")
  eq(fd.by_new[2], { kind = "added", new_line = 2 }, "parse: new line 2 is added")
  eq(fd.by_old[2], { kind = "removed", old_line = 2 }, "parse: old line 2 is removed")
  eq(fd.by_new[4], { kind = "context", old_line = 3, new_line = 4 }, "parse: trailing context maps old 3 -> new 4")
end

do -- position helpers
  eq(position.marker_line(cfg, "comment_1_2"), "<!-- review.gitlab:comment_1_2 -->", "marker line")
  local ids = position.extract_ids("text <!-- review.gitlab:comment_1_2 --> more <!-- review.gitlab:x_9 -->", cfg)
  eq(ids, { comment_1_2 = true, x_9 = true }, "extract_ids finds both markers")
  local body = position.build_body(cfg, { id = "c1", text = "bad", line = 5 })
  check(body:find("bad", 1, true), "body carries the comment text")
  check(body:find("<!%-%- review.gitlab:c1 %-%->", 1), "body carries the marker")
  local multi = position.build_body(cfg, { id = "c2", text = "bad", line = 5, line_end = 7 })
  check(multi:find("5", 1, true) and multi:find("7", 1, true), "multi-line body carries the line range hint")
end

do -- storage: active/<branch> directory
  local storage = require("review-gitlab.storage")
  local dir = storage.review_dir()
  check(dir ~= nil and dir:find("/review/review%.gitlab/active/") ~= nil, "review_dir is stdpath(data)/review/<repo>/active/<branch>")
  local path = storage.get_storage_path()
  check(path ~= nil and path:match("active/.+/comments%.json$") ~= nil, "comments live in active/<branch>/comments.json")
end

do -- store.mark_uploaded (storage mocked so nothing touches disk)
  package.loaded["review-gitlab.storage"] = {
    save = function() end,
    load = function() return {} end,
    git_branch = function() return "br" end,
  }
  package.loaded["review-gitlab.store"] = nil
  local store = require("review-gitlab.store")
  store.reset()
  local c = store.add("m.lua", 2, "hi", nil, "new", { head_sha = "H" })
  check(c.uploaded == false, "new comment is not uploaded")
  check(c.type == nil, "comment carries no type field")
  store.mark_uploaded(c.id, "disc1")
  check(c.uploaded == true and c.discussion_id == "disc1", "mark_uploaded sets the flag and discussion id")
end

do -- ndjson pagination parsing (glab --output ndjson concatenates pages by line)
  local glab = require("review-gitlab.glab")
  local ok, arr = glab._parse_ndjson('{"new_path":"a","diff":""}\n{"new_path":"b","diff":""}\n')
  check(ok and type(arr) == "table" and #arr == 2 and arr[2].new_path == "b", "ndjson lines merge into one array")
  check(glab._parse_ndjson("{\"a\":1}\n{bad}\n") == false, "ndjson reports a malformed line")
end

local REFS = { base_sha = "B", start_sha = "S", head_sha = "H" }
local INDEX = { ["m.lua"] = diff.parse_file("m.lua", "m.lua", DIFF) }

do -- build_position across line kinds
  local added = position.build_position({ file = "m.lua", line = 2, side = "new" }, INDEX["m.lua"], REFS)
  eq({ added.new_line, added.old_line }, { 2, nil }, "added line -> new_line only")
  local ctx = position.build_position({ file = "m.lua", line = 4, side = "new" }, INDEX["m.lua"], REFS)
  eq({ ctx.new_line, ctx.old_line }, { 4, 3 }, "context line -> both lines")
  local removed = position.build_position({ file = "m.lua", line = 2, side = "old" }, INDEX["m.lua"], REFS)
  eq({ removed.old_line, removed.new_line }, { 2, nil }, "removed line -> old_line only")
  local miss, err = position.build_position({ file = "m.lua", line = 99, side = "new" }, INDEX["m.lua"], REFS)
  check(miss == nil and err ~= nil, "line outside the diff is rejected")
end

do -- plan classification
  local comments = {
    { id = "a", file = "m.lua", line = 2, side = "new", text = "x", revisions = { head_sha = "H" } },
    { id = "b", file = "m.lua", line = 0, text = "file" },
    { id = "c", file = "m.lua", line = 2, side = "new", text = "x" }, -- no revisions
    { id = "d", file = "m.lua", line = 2, side = "new", text = "x", revisions = { base_sha = "B" } }, -- working tree: no head_sha
    { id = "e", file = "m.lua", line = 2, side = "new", text = "x", revisions = { head_sha = "OTHER" } },
    { id = "f", file = "m.lua", line = 2, side = "new", text = "x", revisions = { head_sha = "H" } }, -- marker in MR
    { id = "g", file = "m.lua", line = 2, side = "new", text = "x", revisions = { head_sha = "H" }, uploaded = true }, -- local flag
  }
  local ctx = { diff_index = INDEX, diff_refs = REFS, existing_ids = { f = true } }
  local actions = upload.plan(comments, ctx, cfg)
  local kind = {}
  for _, a in ipairs(actions) do
    kind[a.comment.id] = a.kind
  end
  eq(kind, { a = "inline", b = "note", c = "skip", d = "skip", e = "skip", f = "skip", g = "skip" }, "plan classifies each comment")
  check(actions[1].position.new_line == 2, "inline action carries a position")
end

do -- review_branch: target MR comes from comment head_ref, not git HEAD
  local one = select(1, upload.review_branch({
    { id = "a", revisions = { head_ref = "KTN-3840606", head_sha = "H" } },
    { id = "b", revisions = { head_ref = "KTN-3840606", head_sha = "H" } },
  }))
  eq(one, "KTN-3840606", "single review branch resolved from head_ref")
  local multi, err = upload.review_branch({
    { id = "a", revisions = { head_ref = "x", head_sha = "H" } },
    { id = "b", revisions = { head_ref = "y", head_sha = "H" } },
  })
  check(multi == nil and err ~= nil, "multiple review branches -> error")
  local none = upload.review_branch({ { id = "a", revisions = { head_ref = "WORKING" } }, { id = "b" } })
  check(none == nil, "no usable head_ref -> nil (caller falls back to git HEAD)")
end

do -- end-to-end through upload.upload with a fake client + mocked store
  local comments = {
    { id = "a", file = "m.lua", line = 2, side = "new", text = "bug", revisions = { head_sha = "H" } },
  }
  local uploaded = {}
  package.loaded["review-gitlab.store"] = {
    load = function() end,
    get_all = function() return comments end,
    mark_uploaded = function(id, did) uploaded[id] = did end,
  }

  local calls = {}
  local function respond(body)
    return { ok = true, body = body }
  end
  local fake = {
    get = function(ep, cb)
      calls[#calls + 1] = { "get", ep }
      cb(respond({ iid = 7, diff_refs = REFS }))
    end,
    paginate = function(ep, cb)
      calls[#calls + 1] = { "paginate", ep }
      if ep:find("diffs") then
        cb(respond({ { old_path = "m.lua", new_path = "m.lua", diff = DIFF } }))
      else
        cb(respond({})) -- no existing discussions
      end
    end,
    post = function(ep, payload, cb)
      calls[#calls + 1] = { "post", ep, payload }
      cb(respond({ id = "x" }))
    end,
  }

  upload.upload({ "7" }, fake)

  local posts = vim.tbl_filter(function(c) return c[1] == "post" end, calls)
  check(#posts == 1, "one discussion posted")
  check(posts[1][2] == "projects/:id/merge_requests/7/discussions", "posts to the MR's discussions endpoint")
  check(posts[1][3].position ~= nil and posts[1][3].position.new_line == 2, "post carries the inline position")
  check(posts[1][3].body:find("bug", 1, true) ~= nil, "post carries the comment text")
  check(uploaded["a"] == "x", "successful post marks the comment uploaded with its discussion id")
end

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
if failed > 0 then
  os.exit(1)
end
