-- Run from the plugin root: nvim --headless -u NONE -l test/unread.lua
vim.opt.runtimepath:append(vim.fn.getcwd())
vim.cmd('runtime plugin/guh.lua')

local state = require('guh.state')
local gh = require('guh.gh')
local util = require('guh.util')
local pr = require('guh.pr')
local ns = vim.api.nvim_create_namespace('guh.unread')
local original_system = util.system
local original_run_cmds = util.run_cmds
local original_get_notifs = gh.get_user_notifs

-- A later page must contribute unread PRs.
util.system = function(cmd, _, cb)
  assert(vim.deep_equal(cmd, { 'gh', 'api', '--paginate', '--slurp', 'notifications' }))
  cb({ code = 0, stdout = vim.json.encode({
    { { id = '1', repository = { full_name = 'o/r' }, subject = {
      type = 'Issue', url = 'https://api.github.com/repos/o/r/issues/1', title = 'Issue',
    } } },
    { { id = '2', repository = { full_name = 'o/r' }, subject = {
      type = 'PullRequest', url = 'https://api.github.com/repos/o/r/pulls/2', title = 'PR',
    } } },
  }) })
end
local status = state.init_buf('status', nil, nil, 'all')
gh.get_user_notifs(status, function(lines, err)
  assert(lines and not err)
end)
assert(vim.b[status].guh.notifications['o/r#2'].thread_id == '2')

-- The repo loads notifications without displaying the status buffer. Both the
-- open-PR list and gh pr status rows get a marker, without modifying their text.
local current = vim.api.nvim_get_current_buf()
local callback
local repo_buf
util.run_cmds = function(buf, _, cmds, done)
  repo_buf = buf
  util.buf_set_readonly_lines(buf, {
    'Open PRs:', '  #2     PR', '  #3     Read PR',
    'Created by you', '  #2  PR', '  commit #2 is not a PR row',
  }, '')
  cmds[3](buf, nil, nil, function() callback = done end)
end
pr.show_repo(nil, 'o/r')
assert(vim.api.nvim_get_current_buf() == current)
assert(callback)
callback()
local marks = vim.api.nvim_buf_get_extmarks(repo_buf, ns, 0, -1, { details = true })
assert(#marks == 2)
assert(marks[1][2] == 1 and marks[2][2] == 4)
assert(marks[1][4].virt_text[1][1] == ' ● Unread')
assert(vim.api.nvim_buf_get_lines(repo_buf, 1, 2, false)[1] == '  #2     PR')

-- Refreshing with no unread notifications clears existing indicators.
util.system = function(_, _, cb)
  cb({ code = 0, stdout = '[[]]' })
end
pr.show_repo(nil, 'o/r')
callback()
assert(#vim.api.nvim_buf_get_extmarks(repo_buf, ns, 0, -1, {}) == 0)

-- Failure must not block the repo's completion callback.
local warned = false
util.msg = function(message)
  warned = message:find('Unread indicators unavailable', 1, true) ~= nil
end
gh.get_user_notifs = function(_, cb) cb(nil, 'missing scope') end
callback = nil
pr.show_repo(nil, 'o/r')
assert(warned and callback)
callback()

-- Exercise real asynchronous terminal rendering as well as the mocked renderer.
util.run_cmds = function(buf, opts, cmds, done)
  cmds[1] = { 'printf', 'Open PRs:\\n  #2  PR\\n' }
  cmds[2] = { 'printf', 'Created by you:\\n  #2  PR\\n' }
  original_run_cmds(buf, opts, cmds, done)
end
gh.get_user_notifs = function(buf, cb)
  state.set_b_key(buf, { 'guh', 'notifications' }, {
    ['o/r#2'] = { thread_id = '2', is_pr = true },
  })
  cb({ 'Notifications (unread):', '  o/r#2  PR' })
end
pr.show_repo(nil, 'o/r')
assert(vim.wait(3000, function()
  return #vim.api.nvim_buf_get_extmarks(repo_buf, ns, 0, -1, {}) == 2
end), 'terminal rows did not receive indicators')

-- Marking read from a PR clears the repo indicators immediately.
gh.set_notif_read = function(_, cb) cb(true) end
state.init_buf('pr', false, 'o/r', 2)
pr.set_read()
assert(#vim.api.nvim_buf_get_extmarks(repo_buf, ns, 0, -1, {}) == 0)

util.system = original_system
util.run_cmds = original_run_cmds
gh.get_user_notifs = original_get_notifs
print('Unread indicator tests passed')
