local H = dofile("tests/helpers.lua")
local eq, neq, expect_match = H.eq, H.neq, H.expect_match

local store = require("review.store")
local reviewed = require("review.reviewed")

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      store.clear()
      require("review.config").setup()
      reviewed._test.reset()
    end,
  },
})

local function buffer(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  return bufnr
end

T["fingerprints"] = MiniTest.new_set()

T["fingerprints"]["hashes both complete buffers"] = function()
  local old = buffer({ "one", "two" })
  local new = buffer({ "one", "changed" })
  local old_hash, new_hash = reviewed.fingerprint(old, new, "M")
  neq(old_hash, new_hash)
  eq(old_hash, reviewed.fingerprint(old, new, "M"))
  vim.api.nvim_buf_delete(old, { force = true })
  vim.api.nvim_buf_delete(new, { force = true })
end

T["fingerprints"]["distinguishes missing sides from empty buffers"] = function()
  local empty = buffer({ "" })
  local added_missing = reviewed.fingerprint(nil, empty, "A")
  local present_empty = reviewed.fingerprint(empty, empty, "M")
  neq(added_missing, present_empty)
  local _, deleted_missing = reviewed.fingerprint(empty, nil, "D")
  local _, present_new = reviewed.fingerprint(empty, empty, "M")
  neq(deleted_missing, present_new)
  vim.api.nvim_buf_delete(empty, { force = true })
end

T["paths"] = function()
  eq(reviewed._test.path_string({ relative = "./lua/a.lua", absolute = "/repo/lua/a.lua" }, "/repo"), "lua/a.lua")
  eq(reviewed._test.path_string("/repo/lua/a.lua", "/repo"), "lua/a.lua")
  eq(reviewed._test.path_string(nil, "/repo"), nil)
end

T["targets"] = MiniTest.new_set()

T["targets"]["resolves deleted files from the original path and selected group"] = function()
  local tabpage = vim.api.nvim_get_current_tabpage()
  local explorer = {
    data = {
      current_selection = { path = "", old_path = "deleted.lua", group = "staged", status = "D" },
    },
  }
  package.loaded["codediff.ui.lifecycle"] = {
    get_session = function()
      return { refresh = { generation = 7 } }
    end,
    get_panel = function()
      return { name = "explorer", view = explorer }
    end,
    get_git_context = function()
      return { git_root = "/repo" }
    end,
    get_paths = function()
      return { relative = "deleted.lua" }, { relative = "" }
    end,
  }
  reviewed.activate(tabpage)
  local target = reviewed.resolve_target(tabpage)
  eq(target.file, "deleted.lua")
  eq(target.group, "staged")
  eq(target.generation, 7)
  package.loaded["codediff.ui.lifecycle"] = nil
end

T["targets"]["rejects a stale async generation"] = function()
  local first = { tabpage = 1, file = "a.lua", group = "unstaged", old_path = nil, generation = 1 }
  local later = vim.tbl_extend("force", first, { generation = 2 })
  eq(reviewed._test.same_target(first, later), false)
end

T["formatter"] = MiniTest.new_set()

T["formatter"]["delegates, copies, and decorates only active reviewed entries"] = function()
  local reused = {
    left = { { segments = { { text = "file.lua", hl = "Normal" } } } },
    right = { { segments = { { text = "M", hl = "Status" } } } },
  }
  local codediff_config = { options = { explorer = { formatters = {
    file = function()
      return reused
    end,
  } } } }
  package.loaded["codediff.config"] = codediff_config
  package.loaded["codediff.ui.explorer.formatters"] = {
    file = function()
      error("custom formatter should be used")
    end,
  }

  eq(reviewed.install_formatter(), true)
  local formatter = codediff_config.options.explorer.formatters.file
  store.mark_reviewed("file.lua", "unstaged", "old", "new")

  local inactive = formatter({ path = "file.lua", group = "unstaged" })
  eq(inactive, reused)

  reviewed.activate(vim.api.nvim_get_current_tabpage())
  local active = formatter({ path = "file.lua", group = "unstaged" })
  neq(active, reused)
  eq(#active.right, 2)
  eq(active.right[1].segments[1].text, "✓ ")
  eq(reused.right[1].segments[1].text, "M")

  local other = formatter({ path = "other.lua", group = "unstaged" })
  eq(other, reused)
  package.loaded["codediff.config"] = nil
  package.loaded["codediff.ui.explorer.formatters"] = nil
end

T["commands outside a session notify without changing storage"] = function()
  local messages = {}
  local original_notify = vim.notify
  vim.notify = function(message)
    messages[#messages + 1] = message
  end
  reviewed.check_current()
  reviewed.uncheck_current()
  reviewed.toggle_current()
  vim.notify = original_notify
  eq(store.count_reviewed(), 0)
  eq(#messages, 3)
  expect_match(messages[1], "No active Review/CodeDiff explorer session", true)
end

return T
