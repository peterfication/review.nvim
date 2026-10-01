local M = {}

local config = require("review.config")
local store = require("review.store")
local normalize_path = require("review.utils").normalize_path

local active_tabs = {}
local opening = false
local formatter_wrapper
local delegated_formatter

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "review.nvim" })
end

---@param value string|table|nil
---@param git_root? string
---@return string|nil
local function path_string(value, git_root)
  if type(value) == "table" then
    if value.relative and value.relative ~= "" then
      return normalize_path(value.relative)
    end
    value = value.absolute
  end
  if type(value) ~= "string" or value == "" then
    return nil
  end
  if git_root and value:sub(1, #git_root + 1) == git_root .. "/" then
    value = value:sub(#git_root + 2)
  end
  return normalize_path(value)
end

---@param tabpage number
function M.activate(tabpage)
  active_tabs[tabpage] = true
end

---@param tabpage? number
function M.deactivate(tabpage)
  if tabpage then
    active_tabs[tabpage] = nil
  else
    active_tabs = {}
  end
end

function M.begin_open()
  opening = true
end

---@param tabpage number
---@return boolean claimed
function M.claim_open(tabpage)
  if not opening then
    return false
  end
  opening = false
  M.activate(tabpage)
  return true
end

function M.cancel_open()
  opening = false
end

---@param tabpage? number
---@return boolean
function M.is_active(tabpage)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  return active_tabs[tabpage] == true
end

local function formatter_active()
  return opening or M.is_active()
end

---Install the CodeDiff file formatter decorator. Re-running this after a
---CodeDiff setup call safely wraps the formatter that is configured then.
---@return boolean
function M.install_formatter()
  local ok_cfg, codediff_config = pcall(require, "codediff.config")
  local ok_defaults, defaults = pcall(require, "codediff.ui.explorer.formatters")
  if not ok_cfg or not ok_defaults or type(defaults.file) ~= "function" then
    return false
  end

  local explorer = codediff_config.options and codediff_config.options.explorer
  if type(explorer) ~= "table" then
    return false
  end
  explorer.formatters = explorer.formatters or {}
  if formatter_wrapper and explorer.formatters.file == formatter_wrapper then
    return true
  end

  delegated_formatter = explorer.formatters.file or defaults.file
  if not formatter_wrapper then
    formatter_wrapper = function(ctx)
      local layout = delegated_formatter(ctx)
      if not formatter_active() or not M.is_reviewed(ctx.path, ctx.group) then
        return layout
      end

      layout = vim.deepcopy(layout)
      layout.right = layout.right or {}
      local reviewed = config.get().reviewed or {}
      local icon = reviewed.icon or "✓"
      if icon == "" then
        return layout
      end
      local region = {
        segments = { { text = icon .. " ", hl = reviewed.hl or "ReviewReviewed" } },
      }
      table.insert(layout.right, math.max(1, #layout.right), region)
      return layout
    end
  end
  explorer.formatters.file = formatter_wrapper
  return true
end

---@param path string
---@param group string
---@return boolean
function M.is_reviewed(path, group)
  return type(path) == "string" and type(group) == "string" and store.is_reviewed(normalize_path(path), group)
end

---@param tabpage? number
---@return table|nil
function M.resolve_target(tabpage)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  if not M.is_active(tabpage) then
    return nil
  end
  local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
  if not ok or not lifecycle.get_session(tabpage) then
    return nil
  end
  local explorer = require("review.hooks").get_explorer(tabpage)
  local selected = explorer and explorer.data and explorer.data.current_selection
  if not selected or not selected.group then
    return nil
  end

  local session = lifecycle.get_session(tabpage)
  local git_context = lifecycle.get_git_context(tabpage) or {}
  local original, modified = lifecycle.get_paths(tabpage)
  local file = path_string(selected.path, git_context.git_root)
    or path_string(modified, git_context.git_root)
    or path_string(selected.old_path, git_context.git_root)
    or path_string(original, git_context.git_root)
  if not file then
    return nil
  end
  return {
    tabpage = tabpage,
    file = file,
    old_path = path_string(selected.old_path, git_context.git_root),
    group = selected.group,
    status = selected.status,
    generation = session.refresh and session.refresh.generation or nil,
  }
end

---@param bufnr number|nil
---@param missing boolean
---@return string|nil
local function buffer_hash(bufnr, missing)
  if missing then
    return vim.fn.sha256("missing\0")
  end
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local encoded = { "present\0", tostring(#lines), "\0" }
  for _, line in ipairs(lines) do
    encoded[#encoded + 1] = tostring(#line)
    encoded[#encoded + 1] = ":"
    encoded[#encoded + 1] = line
  end
  return vim.fn.sha256(table.concat(encoded))
end

---@param original_buf number|nil
---@param modified_buf number|nil
---@param status? string
---@return string|nil original_hash
---@return string|nil modified_hash
function M.fingerprint(original_buf, modified_buf, status)
  return buffer_hash(original_buf, status == "A" or status == "??"), buffer_hash(modified_buf, status == "D")
end

---@param first table|nil
---@param second table
---@return boolean
local function same_target(first, second)
  return first ~= nil
    and first.tabpage == second.tabpage
    and first.file == second.file
    and first.group == second.group
    and first.old_path == second.old_path
    and first.generation == second.generation
end

---@param target table
---@param lifecycle table
---@return boolean
local function buffers_match_target(target, lifecycle)
  local git_context = lifecycle.get_git_context(target.tabpage) or {}
  local original, modified = lifecycle.get_paths(target.tabpage)
  original = path_string(original, git_context.git_root)
  modified = path_string(modified, git_context.git_root)
  if target.status == "A" or target.status == "??" then
    return modified == target.file
  elseif target.status == "D" then
    return original == (target.old_path or target.file)
  end
  return modified == target.file and original == (target.old_path or target.file)
end

---@param target table
---@param callback fun(original_hash: string, modified_hash: string)
---@param attempt? number
local function after_loaded(target, callback, attempt)
  attempt = attempt or 1
  vim.defer_fn(function()
    local current = M.resolve_target(target.tabpage)
    local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
    if not same_target(current, target) or not ok then
      return
    end
    local session = lifecycle.get_session(target.tabpage)
    if session and session.refresh and session.refresh.loading then
      if attempt < 40 then
        after_loaded(target, callback, attempt + 1)
      end
      return
    end
    if not buffers_match_target(target, lifecycle) then
      if attempt < 40 then
        after_loaded(target, callback, attempt + 1)
      end
      return
    end
    local original_buf, modified_buf = lifecycle.get_buffers(target.tabpage)
    local original_hash, modified_hash = M.fingerprint(original_buf, modified_buf, target.status)
    if original_hash and modified_hash then
      callback(original_hash, modified_hash)
    elseif attempt < 40 then
      after_loaded(target, callback, attempt + 1)
    end
  end, attempt == 1 and 0 or 50)
end

---@param explorer table|nil
local function redraw(explorer)
  if explorer and explorer.tree and type(explorer.tree.render) == "function" and not explorer.is_hidden then
    explorer.tree:render()
  end
end

---@param tabpage? number
function M.redraw(tabpage)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  redraw(require("review.hooks").get_explorer(tabpage))
end

---@param explorer table
---@return table<string, boolean>
local function visible_entries(explorer)
  local entries = {}
  local tree = explorer.tree
  local function walk(node)
    if not node then
      return
    end
    local data = node.data
    if data and not data.type and data.path and data.group then
      entries[data.group .. "\0" .. normalize_path(data.path)] = true
    end
    for _, id in ipairs(node.get_child_ids and node:get_child_ids() or {}) do
      walk(tree:get_node(id))
    end
  end
  for _, node in ipairs(tree and tree:get_nodes() or {}) do
    walk(node)
  end
  return entries
end

---@param target table
---@return number, number
local function progress(target)
  local explorer = require("review.hooks").get_explorer(target.tabpage)
  local entries = explorer and visible_entries(explorer) or {}
  local total, checked = 0, 0
  for key in pairs(entries) do
    total = total + 1
    if store.reviewed_files[key] then
      checked = checked + 1
    end
  end
  return checked, total
end

local function no_session()
  notify("No active Review/CodeDiff explorer session", vim.log.levels.WARN)
end

function M.check_current()
  local target = M.resolve_target()
  if not target then
    no_session()
    return
  end
  after_loaded(target, function(original_hash, modified_hash)
    if not store.is_reviewed(target.file, target.group, original_hash, modified_hash) then
      store.mark_reviewed(target.file, target.group, original_hash, modified_hash)
    end
    local explorer = require("review.hooks").get_explorer(target.tabpage)
    redraw(explorer)
    local checked, total = progress(target)
    notify(string.format("Reviewed %s (%d/%d)", target.file, checked, total))
  end)
end

function M.uncheck_current()
  local target = M.resolve_target()
  if not target then
    no_session()
    return
  end
  after_loaded(target, function()
    store.unmark_reviewed(target.file, target.group)
    local explorer = require("review.hooks").get_explorer(target.tabpage)
    redraw(explorer)
    local checked, total = progress(target)
    notify(string.format("Unreviewed %s (%d/%d)", target.file, checked, total))
  end)
end

---@param on_complete? fun()
function M.toggle_current(on_complete)
  local target = M.resolve_target()
  if not target then
    no_session()
    return
  end
  after_loaded(target, function(original_hash, modified_hash)
    local reviewed = store.is_reviewed(target.file, target.group, original_hash, modified_hash)
    if reviewed then
      store.unmark_reviewed(target.file, target.group)
    else
      store.mark_reviewed(target.file, target.group, original_hash, modified_hash)
    end
    local explorer = require("review.hooks").get_explorer(target.tabpage)
    redraw(explorer)
    local checked, total = progress(target)
    notify(string.format("%s %s (%d/%d)", reviewed and "Unreviewed" or "Reviewed", target.file, checked, total))
    if on_complete then
      on_complete()
    end
  end)
end

---@param tabpage? number
function M.validate_current(tabpage)
  local target = M.resolve_target(tabpage)
  if not target or not store.get_reviewed(target.file, target.group) then
    return
  end
  after_loaded(target, function(original_hash, modified_hash)
    if store.is_reviewed(target.file, target.group, original_hash, modified_hash) then
      return
    end
    store.unmark_reviewed(target.file, target.group)
    redraw(require("review.hooks").get_explorer(target.tabpage))
  end)
end

M._test = {
  path_string = path_string,
  same_target = same_target,
  visible_entries = visible_entries,
  formatter_active = formatter_active,
  reset = function()
    active_tabs = {}
    opening = false
  end,
}

return M
