-- Run from the plugin root: nvim --headless -u NONE -l test/files.lua
vim.opt.runtimepath:append(vim.fn.getcwd())

local files = require('guh.files')

local list = files.list({
  file_paths = { ['b.lua'] = true, ['a.lua'] = true, ['c/d.lua'] = true },
  viewed = { ['b.lua'] = true, ['gone.lua'] = true },
})
assert(vim.deep_equal(list, {
  { path = 'a.lua', viewed = false },
  { path = 'b.lua', viewed = true },
  { path = 'c/d.lua', viewed = false },
}))

-- Off-diff (quasi) sections come first; real headings are keyed by the post-image path.
local headings = files.headings({
  'diff --git a/outdated-1:a.lua b/outdated-1:a.lua',
  '@@ -1 +1 @@',
  'diff --git a/a.lua b/a.lua',
  '+x',
  '(viewed) b.lua',
  'diff --git a/old/d.lua b/c/d.lua',
  'diff --git a/a.lua b/a.lua',
})
assert(vim.deep_equal(headings, {
  ['outdated-1:a.lua'] = 1,
  ['a.lua'] = 3,
  ['b.lua'] = 5,
  ['c/d.lua'] = 6,
}))

assert(vim.deep_equal(files.unviewed_items(list, headings, 7), {
  { bufnr = 7, lnum = 3, text = 'a.lua' },
  { bufnr = 7, lnum = 6, text = 'c/d.lua' },
}))

assert(files.format(list[1]) == '[ ] a.lua')
assert(files.format(list[2]) == '[✓] b.lua')

print('ok')
