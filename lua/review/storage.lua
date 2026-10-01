local M = {}

local data_dir = vim.fn.stdpath("data") .. "/review"

---@type {rev1: string, rev2: string}|nil
---@return string|nil
local function get_git_root()
  local handle = io.popen("git rev-parse --show-toplevel 2>/dev/null")
  if handle then
    local result = handle:read("*a")
    handle:close()
    if result and result ~= "" then
      return result:gsub("%s+$", "")
    end
  end
  return nil
end

---@return string|nil
function M.git_branch()
  local handle = io.popen("git rev-parse --abbrev-ref HEAD 2>/dev/null")
  if handle then
    local result = handle:read("*a")
    handle:close()
    if result and result ~= "" then
      return result:gsub("%s+$", "")
    end
  end
  return nil
end

---@param str string
---@return string
local function hash(str)
  local h = 0
  for i = 1, #str do
    h = ((h * 31) + string.byte(str, i)) % 2147483647
  end
  return string.format("%x", h)
end

---@return string|nil project hash for the current repo, nil outside git
local function project_hash()
  local git_root = get_git_root()
  if not git_root then
    return nil
  end
  pcall(vim.fn.mkdir, data_dir, "p")
  return hash(git_root)
end

---One file per repository: comments and notes live together until the
---review is closed (or :Review clear), which archives and clears them.
---@return string|nil
function M.get_storage_path()
  local h = project_hash()
  if not h then
    return nil
  end
  return string.format("%s/%s.json", data_dir, h)
end

---Where releases before the per-repo store kept the current branch's comments.
---@return string|nil
function M.legacy_storage_path()
  local h = project_hash()
  local branch = M.git_branch()
  if not h or not branch then
    return nil
  end
  local safe_branch = branch:gsub("[^%w%-_]", "_")
  return string.format("%s/%s-%s.json", data_dir, h, safe_branch)
end

---@return string
function M.archive_dir()
  return data_dir .. "/archive"
end

---Move the live file into the archive so a close or clear never loses text.
---@return string|nil archived file path, nil when there was nothing to archive
function M.archive()
  local path = M.get_storage_path()
  if not path or vim.fn.filereadable(path) == 0 then
    return nil
  end
  local dir = M.archive_dir()
  pcall(vim.fn.mkdir, dir, "p")
  local h = vim.fn.fnamemodify(path, ":t:r")
  local target = string.format("%s/%s-%s.json", dir, h, os.date("%Y%m%d-%H%M%S"))
  local n = 1
  while vim.fn.filereadable(target) == 1 do
    target = string.format("%s/%s-%s-%d.json", dir, h, os.date("%Y%m%d-%H%M%S"), n)
    n = n + 1
  end
  if os.rename(path, target) then
    return target
  end
  return nil
end

local VERSION = 2

---@param value any
---@return boolean
local function is_reviewed_entry(value)
  return type(value) == "table"
    and type(value.file) == "string"
    and value.file ~= ""
    and type(value.group) == "string"
    and value.group ~= ""
    and type(value.original_hash) == "string"
    and type(value.modified_hash) == "string"
    and type(value.reviewed_at) == "number"
end

---Normalize the on-disk representation. Files without a version field are the
---original raw file -> comments map.
---@param data any
---@return {version: 2, comments: table, reviewed_files: table}
function M.normalize(data)
  if type(data) ~= "table" then
    data = {}
  end

  if data.version == nil then
    return { version = VERSION, comments = data, reviewed_files = {} }
  end

  local comments = type(data.comments) == "table" and data.comments or {}
  local reviewed_files = {}
  if type(data.reviewed_files) == "table" then
    local normalize_path = require("review.utils").normalize_path
    for _, entry in pairs(data.reviewed_files) do
      if is_reviewed_entry(entry) then
        local copy = vim.deepcopy(entry)
        copy.file = normalize_path(copy.file)
        if copy.file ~= "" then
          reviewed_files[copy.group .. "\0" .. copy.file] = copy
        end
      end
    end
  end

  return { version = VERSION, comments = comments, reviewed_files = reviewed_files }
end

---@param state table versioned review state (raw v1 comment maps are accepted)
function M.save(state)
  local path = M.get_storage_path()
  if not path then
    return
  end

  -- vim.fn.json_encode treats NUL-containing map keys as Vim special-dict
  -- metadata. vim.json preserves the `group .. "\0" .. path` identity and
  -- writes the separator as JSON's portable \u0000 escape.
  local data = vim.json.encode(M.normalize(state))
  local file = io.open(path, "w")
  if file then
    file:write(data)
    file:close()
  end
end

-- Archived exports are kept for 30 days. The live file never expires:
-- notes are meant to accumulate while you browse.
local ARCHIVE_EXPIRY_SECONDS = 30 * 24 * 60 * 60
local cleanup_scheduled = false

function M.cleanup_expired()
  local now = os.time()
  for _, filepath in ipairs(vim.fn.glob(M.archive_dir() .. "/*.json", false, true)) do
    local mtime = vim.fn.getftime(filepath)
    if mtime > 0 and (now - mtime) > ARCHIVE_EXPIRY_SECONDS then
      os.remove(filepath)
    end
  end
end

local function schedule_cleanup()
  if cleanup_scheduled then
    return
  end
  cleanup_scheduled = true
  vim.defer_fn(M.cleanup_expired, 0)
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
    local ok, data = pcall(vim.json.decode, content)
    if ok and type(data) == "table" then
      return data
    end
  end
  return nil
end

---@return table
function M.load()
  schedule_cleanup()

  local path = M.get_storage_path()
  if not path then
    return M.normalize(nil)
  end

  local data = read_json(path)
  if data then
    return M.normalize(data)
  end

  -- First run after the per-repo store: adopt the current branch's old file
  local legacy = M.legacy_storage_path()
  if legacy and vim.fn.filereadable(legacy) == 1 then
    data = read_json(legacy)
    if data then
      M.save(data)
      return M.normalize(data)
    end
  end

  return M.normalize(nil)
end

function M.clear()
  local path = M.get_storage_path()
  if path then
    os.remove(path)
  end
end

return M
