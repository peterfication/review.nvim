local H = dofile("tests/helpers.lua")
local eq, neq, expect_match, expect_truthy = H.eq, H.neq, H.expect_match, H.expect_truthy

local storage = require("review.storage")

local function reset_disk()
  storage.clear()
  vim.fn.delete(storage.archive_dir(), "rf")
  local legacy = storage.legacy_storage_path()
  if legacy then
    vim.fn.delete(legacy)
  end
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = reset_disk,
    post_once = reset_disk,
  },
})

T["get_storage_path"] = MiniTest.new_set()

T["get_storage_path"]["is one file per repository, not per branch"] = function()
  local path = storage.get_storage_path()
  neq(path, nil)
  expect_match(path, "/review/%x+%.json$")
  eq(path:find(storage.git_branch(), 1, true), nil)
end

T["get_storage_path"]["legacy path carried the branch name"] = function()
  local legacy = storage.legacy_storage_path()
  local safe_branch = storage.git_branch():gsub("[^%w%-_]", "_")
  expect_match(legacy, "/review/%x+%-" .. vim.pesc(safe_branch) .. "%.json$")
end

T["archive"] = MiniTest.new_set()

T["archive"]["moves the live file into archive/ and keeps its contents"] = function()
  storage.save({ ["a.lua"] = { { file = "a.lua", line = 1, type = "note", text = "keep me" } } })
  local archived = storage.archive()
  neq(archived, nil)
  expect_match(archived, "/review/archive/%x+%-%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%.json$")
  eq(vim.fn.filereadable(storage.get_storage_path()), 0)
  expect_match(table.concat(vim.fn.readfile(archived), "\n"), "keep me", true)
end

T["archive"]["returns nil when there is nothing to archive"] = function()
  eq(storage.archive(), nil)
  eq(vim.fn.isdirectory(storage.archive_dir()), 0)
end

T["load"] = MiniTest.new_set()

T["load"]["adopts the old per-branch file on first run"] = function()
  vim.fn.writefile({ '{"b.lua":[{"file":"b.lua","line":2,"type":"issue","text":"from before"}]}' }, storage.legacy_storage_path())
  local data = storage.load()
  eq(data.version, 2)
  eq(data.comments["b.lua"][1].text, "from before")
  eq(data.reviewed_files, {})
  eq(vim.fn.filereadable(storage.get_storage_path()), 1)
end

T["load"]["returns an empty table when nothing is stored"] = function()
  eq(storage.load(), { version = 2, comments = {}, reviewed_files = {} })
end

T["load"]["migrates a version 1 comment map in memory"] = function()
  vim.fn.writefile({ '{"old.lua":[{"file":"old.lua","line":4,"type":"note","text":"keep"}]}' }, storage.get_storage_path())
  local data = storage.load()
  eq(data.version, 2)
  eq(data.comments["old.lua"][1].text, "keep")
  eq(data.reviewed_files, {})
  eq(table.concat(vim.fn.readfile(storage.get_storage_path()), "\n"):find('"version"', 1, true), nil)
end

T["load"]["round trips version 2 review data"] = function()
  storage.save({
    version = 2,
    comments = { ["a.lua"] = { { file = "a.lua", line = 1, type = "note", text = "text" } } },
    reviewed_files = {
      ["unstaged\0a.lua"] = {
        file = "a.lua",
        group = "unstaged",
        original_hash = "old",
        modified_hash = "new",
        reviewed_at = 123,
      },
    },
  })
  local data = storage.load()
  eq(data.comments["a.lua"][1].text, "text")
  eq(data.reviewed_files["unstaged\0a.lua"].reviewed_at, 123)
end

T["load"]["drops malformed reviewed entries"] = function()
  storage.save({
    version = 2,
    comments = {},
    reviewed_files = {
      bad = { file = "bad.lua", group = "unstaged", original_hash = "old" },
      good = {
        file = "./good.lua",
        group = "staged",
        original_hash = "old",
        modified_hash = "new",
        reviewed_at = 1,
      },
    },
  })
  local data = storage.load()
  eq(vim.tbl_count(data.reviewed_files), 1)
  eq(data.reviewed_files["staged\0good.lua"].file, "good.lua")
end

T["cleanup_expired"] = MiniTest.new_set()

T["cleanup_expired"]["drops old archives and never the live file"] = function()
  storage.save({})
  local live = storage.get_storage_path()
  vim.fn.mkdir(storage.archive_dir(), "p")
  local old = storage.archive_dir() .. "/old.json"
  local fresh = storage.archive_dir() .. "/fresh.json"
  vim.fn.writefile({ "{}" }, old)
  vim.fn.writefile({ "{}" }, fresh)
  vim.fn.system({ "touch", "-t", "202001010000", old, live })
  storage.cleanup_expired()
  eq(vim.fn.filereadable(old), 0)
  eq(vim.fn.filereadable(fresh), 1)
  eq(vim.fn.filereadable(live), 1)
end

T["archive"]["keeps comments and reviewed files together"] = function()
  storage.save({
    version = 2,
    comments = { ["a.lua"] = { { text = "comment text" } } },
    reviewed_files = {
      one = {
        file = "a.lua",
        group = "unstaged",
        original_hash = "before-hash",
        modified_hash = "after-hash",
        reviewed_at = 1,
      },
    },
  })
  local archived = storage.archive()
  local contents = table.concat(vim.fn.readfile(archived), "\n")
  expect_match(contents, "comment text", true)
  expect_match(contents, "before%-hash")
end

return T
