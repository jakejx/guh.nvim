--- Pure helpers for the PR file list ("Viewed" state, diff headings).

local M = {}

--- @class GuhFile
--- @field path string
--- @field viewed boolean

--- PR files with their "Viewed" state, sorted by path.
---
--- @param pr_data PullRequest
--- @return GuhFile[]
function M.list(pr_data)
  local files = {}
  for path in pairs(pr_data.file_paths or {}) do
    files[#files + 1] = { path = path, viewed = (pr_data.viewed or {})[path] == true }
  end
  table.sort(files, function(a, b)
    return a.path < b.path
  end)
  return files
end

--- Maps each file path to the 1-indexed line of its `diff --git …` or `(viewed) …` heading.
---
--- @param lines string[] prdiff buffer lines.
--- @return table<string, integer>
function M.headings(lines)
  local out = {}
  for i, l in ipairs(lines) do
    local path = l:match('^diff %-%-git a/.- b/(.+)$') or l:match('^%(viewed%) (.+)$')
    if path and not out[path] then
      out[path] = i
    end
  end
  return out
end

--- Location-list items for files not yet "Viewed".
---
--- @param files GuhFile[]
--- @param headings table<string, integer>
--- @param bufnr integer
--- @return vim.quickfix.entry[]
function M.unviewed_items(files, headings, bufnr)
  local items = {}
  for _, f in ipairs(files) do
    if not f.viewed then
      items[#items + 1] = { bufnr = bufnr, lnum = headings[f.path] or 1, text = f.path }
    end
  end
  return items
end

--- @param file GuhFile
--- @return string
function M.format(file)
  return ('%s %s'):format(file.viewed and '[✓]' or '[ ]', file.path)
end

return M
