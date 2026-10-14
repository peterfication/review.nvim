local M = {}

local storage = require("review.storage")

---@class Comment
---@field id string
---@field file string
---@field line number
---@field line_end? number
---@field side? "old"|"new"
---@field type "note"|"suggestion"|"issue"|"praise"
---@field text string
---@field created_at number
---@field branch? string branch checked out when the comment was made

---@type table<string, Comment[]>
M.comments = {}

---@class ReviewedFile
---@field file string
---@field group string
---@field original_hash string
---@field modified_hash string
---@field reviewed_at number

---@type table<string, ReviewedFile>
M.reviewed_files = {}

local id_counter = 0
local loaded = false

---@return string
local function generate_id()
  id_counter = id_counter + 1
  return string.format("comment_%d_%d", os.time(), id_counter)
end

local function persist()
  storage.save({
    version = 2,
    comments = M.comments,
    reviewed_files = M.reviewed_files,
  })
end

function M.reset()
  M.comments = {}
  M.reviewed_files = {}
  id_counter = 0
  loaded = false
end

function M.load()
  if loaded then
    return
  end
  local data = storage.load()
  M.comments = data.comments
  M.reviewed_files = data.reviewed_files
  -- Update id_counter to avoid collisions
  for _, comments in pairs(M.comments) do
    for _, comment in ipairs(comments) do
      local num = tonumber(comment.id:match("comment_%d+_(%d+)"))
      if num and num > id_counter then
        id_counter = num
      end
    end
  end
  loaded = true
end

---@param file string
---@param group string
---@return string
local function reviewed_key(file, group)
  return group .. "\0" .. require("review.utils").normalize_path(file)
end

---@param file string
---@param group string
---@param original_hash string
---@param modified_hash string
---@param reviewed_at? number
---@return ReviewedFile
function M.mark_reviewed(file, group, original_hash, modified_hash, reviewed_at)
  file = require("review.utils").normalize_path(file)
  local entry = {
    file = file,
    group = group,
    original_hash = original_hash,
    modified_hash = modified_hash,
    reviewed_at = reviewed_at or os.time(),
  }
  M.reviewed_files[reviewed_key(file, group)] = entry
  persist()
  return entry
end

---@param file string
---@param group string
---@return boolean removed
function M.unmark_reviewed(file, group)
  local key = reviewed_key(file, group)
  if not M.reviewed_files[key] then
    return false
  end
  M.reviewed_files[key] = nil
  persist()
  return true
end

---@param file string
---@param group string
---@return ReviewedFile|nil
function M.get_reviewed(file, group)
  return M.reviewed_files[reviewed_key(file, group)]
end

---@param file string
---@param group string
---@param original_hash? string
---@param modified_hash? string
---@return boolean
function M.is_reviewed(file, group, original_hash, modified_hash)
  local entry = M.get_reviewed(file, group)
  if not entry then
    return false
  end
  if original_hash ~= nil and entry.original_hash ~= original_hash then
    return false
  end
  if modified_hash ~= nil and entry.modified_hash ~= modified_hash then
    return false
  end
  return true
end

---@return ReviewedFile[]
function M.list_reviewed()
  local entries = {}
  for _, entry in pairs(M.reviewed_files) do
    entries[#entries + 1] = vim.deepcopy(entry)
  end
  table.sort(entries, function(a, b)
    if a.group ~= b.group then
      return a.group < b.group
    end
    return a.file < b.file
  end)
  return entries
end

---@return number
function M.count_reviewed()
  return vim.tbl_count(M.reviewed_files)
end

---@param file string
---@param line number
---@param type "note"|"suggestion"|"issue"|"praise"
---@param text string
---@param line_end? number
---@param side? "old"|"new"
---@return Comment
function M.add(file, line, type, text, line_end, side)
  if not M.comments[file] then
    M.comments[file] = {}
  end

  local comment = {
    id = generate_id(),
    file = file,
    line = line,
    line_end = (line_end and line_end ~= line) and line_end or nil,
    side = side or "new",
    type = type,
    text = text,
    created_at = os.time(),
    branch = storage.git_branch(),
  }

  table.insert(M.comments[file], comment)
  persist()
  return comment
end

---@param id string
---@return Comment|nil
function M.get(id)
  for _, comments in pairs(M.comments) do
    for _, comment in ipairs(comments) do
      if comment.id == id then
        return comment
      end
    end
  end
  return nil
end

---@param file string
---@param side? "old"|"new"
---@return Comment[]
function M.get_for_file(file, side)
  local comments = M.comments[file] or {}
  if not side then
    return comments
  end
  local filtered = {}
  for _, comment in ipairs(comments) do
    if comment.line == 0 or (comment.side or "new") == side then
      table.insert(filtered, comment)
    end
  end
  return filtered
end

---@param file string
---@return Comment|nil
function M.get_file_comment(file)
  local comments = M.comments[file] or {}
  for _, comment in ipairs(comments) do
    if comment.line == 0 then
      return comment
    end
  end
  return nil
end

---@param file string
---@param line number
---@param side? "old"|"new"
---@return Comment|nil
function M.get_at_line(file, line, side)
  local comments = M.comments[file] or {}
  for _, comment in ipairs(comments) do
    local line_end = comment.line_end or comment.line
    if line >= comment.line and line <= line_end then
      if not side or (comment.side or "new") == side then
        return comment
      end
    end
  end
  return nil
end

---@param file string
---@param start_line number
---@param end_line number
---@param side? "old"|"new"
---@return Comment|nil
function M.get_overlapping(file, start_line, end_line, side)
  local comments = M.comments[file] or {}
  for _, comment in ipairs(comments) do
    local c_end = comment.line_end or comment.line
    if comment.line <= end_line and c_end >= start_line then
      if not side or (comment.side or "new") == side then
        return comment
      end
    end
  end
  return nil
end

---@param id string
---@param text string
---@param new_type? "note"|"suggestion"|"issue"|"praise"
---@return boolean
function M.update(id, text, new_type)
  for _, comments in pairs(M.comments) do
    for _, comment in ipairs(comments) do
      if comment.id == id then
        comment.text = text
        if new_type then
          comment.type = new_type
        end
        persist()
        return true
      end
    end
  end
  return false
end

---Move a comment to new lines (used when the buffer it lives in was edited).
---@param id string
---@param line number
---@param line_end? number
---@return boolean
function M.move(id, line, line_end)
  local comment = M.get(id)
  if not comment then
    return false
  end
  comment.line = line
  comment.line_end = (line_end and line_end ~= line) and line_end or nil
  persist()
  return true
end

---@param id string
---@return boolean
function M.delete(id)
  for file, comments in pairs(M.comments) do
    for i, comment in ipairs(comments) do
      if comment.id == id then
        table.remove(comments, i)
        if #comments == 0 then
          M.comments[file] = nil
        end
        persist()
        return true
      end
    end
  end
  return false
end

---@return Comment[]
function M.get_all()
  local all = {}
  for _, comments in pairs(M.comments) do
    for _, comment in ipairs(comments) do
      table.insert(all, comment)
    end
  end
  table.sort(all, function(a, b)
    if a.file ~= b.file then
      return a.file < b.file
    end
    return a.line < b.line
  end)
  return all
end

---@return table<string, Comment[]>
function M.get_all_by_file()
  return M.comments
end

---@return number
function M.count()
  local count = 0
  for _, comments in pairs(M.comments) do
    count = count + #comments
  end
  return count
end

---Comments made on other branches than `branch`, grouped by branch name.
---@param branch string|nil
---@return table<string, number> counts by branch
function M.count_from_other_branches(branch)
  local counts = {}
  for _, comments in pairs(M.comments) do
    for _, comment in ipairs(comments) do
      if comment.branch and branch and comment.branch ~= branch then
        counts[comment.branch] = (counts[comment.branch] or 0) + 1
      end
    end
  end
  return counts
end

---Archive the persisted file and start over. Nothing is deleted outright.
---@return string|nil archived file path
function M.archive_and_clear()
  local archived = storage.archive()
  M.reset()
  storage.clear()
  return archived
end

function M.clear()
  M.archive_and_clear()
end

return M
