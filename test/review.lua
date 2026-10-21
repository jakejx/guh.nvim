-- Run from the plugin root: nvim --headless -u NONE -l test/review.lua
vim.opt.runtimepath:append(vim.fn.getcwd())
vim.cmd('runtime plugin/guh.lua')
local gh = require('guh.gh')
local pr = require('guh.pr')
local state = require('guh.state')
local util = require('guh.util')
local comments = require('guh.comments')

local request, response, code
util.system = function(cmd, _, cb)
  request = cmd
  cb({ code = code or 0, stdout = vim.json.encode(response), stderr = 'request failed' })
end
local function fields()
  local result = {}
  for i = 6, #request, 2 do
    local k, v = request[i + 1]:match('^([^=]+)=(.*)$')
    result[k] = v
  end
  return result
end
gh.get_user = function() return 'reviewer' end
response = { data = { repository = { pullRequest = { id = 'PR', reviews = { nodes = { { id = 'PENDING' } } } } } } }
gh.get_review_context(92, 'owner/repo', function(id, review, err)
  assert(id == 'PR' and review == 'PENDING' and not err)
end)
assert(fields().author == 'reviewer')
assert(fields().query:find('states: [PENDING]', 1, true))
response.data.repository.pullRequest.reviews.nodes = {}
gh.get_review_context(92, 'owner/repo', function(id, review, err)
  assert(id == 'PR' and not review and not err)
end)
response = { data = { repository = { pullRequest = vim.NIL } } }
gh.get_review_context(92, 'owner/repo', function(id, _, err) assert(not id and err) end)
response = { message = 'Forbidden' }
code = 1
gh.get_review_context(92, 'owner/repo', function(id, _, err) assert(not id and err == 'Forbidden') end)
code = 0
response = { data = { addPullRequestReviewThread = { thread = { id = 'THREAD' } } } }
for _, side in ipairs({ 'LEFT', 'RIGHT' }) do
  gh.new_review_comment('PENDING', 'body', 'file.lua', 4, 4, side, function(r) assert(not r.errors) end)
  local f = fields()
  assert(f.review == 'PENDING' and f.side == side and f.line == '4')
  assert(not f.startLine and not f.startSide, 'single-line threads must omit startLine/startSide')
  gh.new_review_comment('PENDING', 'body', 'file.lua', 2, 4, side, function(r) assert(not r.errors) end)
  f = fields()
  assert(f.startLine == '2' and f.startSide == side, 'multiline threads must set startSide')
end
response = { data = { submitPullRequestReview = { pullRequestReview = { id = 'PENDING' } } } }
gh.review_pending_pr('PENDING', 'approve', nil, function(ok) assert(ok) end)
assert(fields().event == 'APPROVE' and not fields().body)
gh.review_pending_pr('PENDING', 'request-changes', 'fix this', function(ok) assert(ok) end)
assert(fields().event == 'REQUEST_CHANGES' and fields().body == 'fix this')
response = { errors = { { message = 'denied' } } }
gh.review_pending_pr('PENDING', 'comment', 'body', function(ok, err) assert(not ok and err == 'denied') end)

-- Exercise UI routing with fresh server state, not cached review history.
local pending, context_error, sent, result, context_calls
context_calls = 0
gh.get_review_context = function(id, repo, cb)
  assert(id == 92 and repo == 'owner/repo')
  context_calls = context_calls + 1
  cb('PR', pending, context_error)
end
util.progress = function()
  return function(status) result = status end
end
local buf = state.init_buf('pr', false, 'owner/repo', 92)
state.set_b_key(buf, { 'guh', 'pr_data' }, { number = 92, reviews = {} })
gh.start_review = function(id, cb)
  assert(id == 'PR')
  pending = 'PENDING'
  sent = 'start'
  cb({ data = { addPullRequestReview = { pullRequestReview = { id = pending } } } })
end
pr.start_review()
assert(sent == 'start' and result == 'success')
sent = nil
pr.start_review()
assert(not sent and result == 'success', 'starting twice should reuse the pending review')

vim.ui.select = function(_, _, cb) cb('Approve') end
comments.edit_comment = function(kind, id, _, opts, cb)
  assert(kind == 'review' and id == 92 and opts.allow_empty)
  cb('')
end
gh.review_pending_pr = function(review, action, body, cb)
  assert(review == pending and action == 'approve' and body == '')
  sent = 'pending'
  pending = nil
  cb(true)
end
gh.review_pr = function(id, repo, action, body, cb)
  assert(id == 92 and repo == 'owner/repo' and action == 'approve' and body == '')
  sent = 'single'
  cb(true)
end
pr.review_pr()
assert(sent == 'pending' and result == 'success')
pr.review_pr()
assert(sent == 'single', 'a submitted review must not be reused')
context_error = 'network error'
sent = nil
pr.review_pr()
assert(not sent and result == 'failed', 'lookup failure must not publish a standalone review')
context_error = nil

-- Lookup happens after composing a diff comment, so externally started reviews
-- are honored and a failed lookup never silently publishes a pending comment.
comments.prepare_to_comment = function()
  return { start_line = 2, end_line = 3, file = 'file.lua', side = 'LEFT' }
end
util.hl_flash = function() end
util.new_progress_report = util.progress
comments.edit_comment = function(_, _, _, _, cb) cb('diff comment') end
gh.get_pr_data = function(_, _, _, cb) cb({ number = 92, headRefOid = 'HEAD' }) end
pr.refresh = function() end
gh.new_review_comment = function(review, body, path, first, last, side, cb)
  assert(review == 'PENDING' and body == 'diff comment' and path == 'file.lua')
  assert(first == 2 and last == 3 and side == 'LEFT')
  sent = 'pending thread'
  cb({})
end
gh.new_comment = function(_, _, _, _, _, _, _, cb)
  sent = 'single thread'
  cb({})
end
local function comment()
  local before = context_calls
  pr.comment({ line1 = 2, line2 = 3, range = 1 })
  assert(vim.wait(1000, function() return context_calls > before end))
end
pending = 'PENDING'
comment()
assert(sent == 'pending thread')
pending = nil
comment()
assert(sent == 'single thread')
context_error = 'network error'
sent = nil
comment()
assert(not sent and result == 'failed')

-- Non-PR buffers fail before issuing API requests.
state.init_buf('issue', false, 'owner/repo', 92)
assert(not pcall(pr.start_review))
assert(vim.fn.maparg('<Plug>(guh-start-review)', 'n') ~= '')
print('Pending review tests passed')
