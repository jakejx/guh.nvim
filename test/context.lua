-- Run from the plugin root: nvim --headless -u NONE -l test/context.lua
vim.opt.runtimepath:append(vim.fn.getcwd())
vim.cmd('runtime plugin/guh.lua')

local comments = require('guh.comments')
local guh = require('guh')
local state = require('guh.state')
local repo = 'o/r'
local sha = 'abcdef0123456789abcdef0123456789abcdef01'
local failures, passed = {}, 0

local function eq(actual, expected)
  assert(vim.deep_equal(actual, expected), ('expected %s, got %s'):format(vim.inspect(expected), vim.inspect(actual)))
end

local function fields(actual, expected)
  for key, value in pairs(expected) do
    eq(actual[key], value)
  end
end

local function absent(actual, keys)
  for _, key in ipairs(keys) do
    eq(actual[key], nil)
  end
end

local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    passed = passed + 1
  else
    failures[#failures + 1] = name .. ': ' .. err
  end
end

local function buffer(feat, owner, id, lines, extra)
  local buf = state.init_buf(feat, nil, owner, id, extra)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

-- Every API call must leave all buffers, their contents/state, windows and
-- cursors alone, including the hidden status buffer consulted for notifications.
local function snapshot()
  local result = {
    buf = vim.api.nvim_get_current_buf(),
    win = vim.api.nvim_get_current_win(),
    buffers = {},
    windows = {},
  }
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    result.buffers[buf] = {
      name = vim.api.nvim_buf_get_name(buf),
      lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
      vars = vim.fn.getbufvar(buf, ''),
      tick = vim.api.nvim_buf_get_changedtick(buf),
      modified = vim.bo[buf].modified,
    }
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    result.windows[win] = { buf = vim.api.nvim_win_get_buf(win), cursor = vim.api.nvim_win_get_cursor(win) }
  end
  return result
end

local function context(buf, row, col)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { row or 1, col or 0 })
  local before = snapshot()
  local ctx = guh.get_context()
  eq(snapshot(), before)
  if ctx then
    fields(ctx, { bufnr = buf, feat = vim.b[buf].guh.feat, row = row or 1, col = col or 0 })
  end
  return ctx
end

-- Fail immediately if a read-only context query tries to launch a command.
vim.system = function()
  error('get_context must not launch a process')
end
require('guh.util').system = function()
  error('get_context must not fetch data')
end
require('guh.util').run_cmds = function()
  error('get_context must not render commands')
end

local job = { databaseId = 456, runId = 123, workflowId = 789, workflowName = 'Checks', name = 'Checks: tests' }
local pr_data = {
  number = 42,
  title = 'Example PR',
  baseRefOid = string.rep('b', 40),
  headRefOid = sha,
  baseRefName = 'main',
  headRefName = 'feature',
  commits = { { oid = sha, messageHeadline = 'Implement feature' } },
  ci_jobs = { job },
  viewed = {},
}
local pr = buffer('pr', repo, 42, {
  '## Commits (1)',
  'Revision ' .. sha:sub(1, 7),
  sha:sub(1, 7) .. '  Implement feature',
  'See elsewhere/project#99',
}, { pr_data = pr_data })
local status = buffer('status', nil, 'all', {
  'Notifications (unread):',
  '  o/r#42  Example notification title',
  '  o/r#43  Issue notification title',
}, {
  notifications = {
    ['o/r#42'] = { thread_id = 'notif-pr', is_pr = true },
    ['o/r#43'] = { thread_id = 'notif-issue', is_pr = false },
  },
})

test('nil outside Guh', function()
  local buf = vim.api.nvim_create_buf(true, true)
  eq(context(buf), nil)
  vim.b[buf].guh = { repo = repo } -- A partial dict is not a Guh view.
  eq(context(buf), nil)
end)

test('enclosing PR and cached metadata', function()
  local ctx = context(pr)
  fields(ctx, {
    repo = repo,
    number = 42,
    pr_number = 42,
    pr = pr_data,
    base_sha = pr_data.baseRefOid,
    head_sha = sha,
    base_branch = 'main',
    head_branch = 'feature',
    notification_id = 'notif-pr',
  })
  absent(ctx, { 'issue_number', 'target', 'sha' })
end)

test('cursor SHA resolves full cached commit without replacing PR', function()
  local ctx = context(pr, 2, 9)
  fields(ctx, { repo = repo, pr_number = 42, number = 42, sha = sha })
  eq(ctx.target, { repo = repo, sha = sha })
end)

test('commit row cursor on message', function()
  local ctx = context(pr, 3, 12)
  eq(ctx.target, { repo = repo, sha = sha })
  fields(ctx, { pr_number = 42, sha = sha })
end)

test('repo sections identify PRs and issues with cursor on title', function()
  local buf = buffer('repo', repo, 'all', {
    'Open PRs:',
    '  #51  First pull request',
    'Open issues:',
    '  #52  First issue',
    'Created by you',
    '  #53  Another pull request',
  })
  for _, case in ipairs({ { 2, 51, 'pr_number' }, { 4, 52, 'issue_number' }, { 6, 53, 'pr_number' } }) do
    local ctx = context(buf, case[1], 10)
    fields(ctx, { repo = repo, number = case[2], [case[3]] = case[2] })
    eq(ctx.target, { repo = repo, number = case[2], [case[3]] = case[2] })
    eq(ctx[case[3] == 'pr_number' and 'issue_number' or 'pr_number'], nil)
    -- Same identity when the cursor is on the bare #number token.
    eq(context(buf, case[1], 3).target, ctx.target)
  end
end)

test('repository commit and branch rows and explicit status references', function()
  local buf = buffer('repo', repo, 'all', {
    'Recent commits:',
    '  123456789012  Numeric hash',
    'Branches (last-updated):',
    '  o/r/tree/feature/nested',
    'guh://status',
  })
  fields(context(buf, 2, 17), { repo = repo, sha = '123456789012' })
  fields(context(buf, 4, 0), { repo = repo, branch = 'feature/nested' })
  eq(context(buf, 5).target, { status = true })
end)

test('notification row title retains notification and subject kind', function()
  for _, case in ipairs({ { 2, 42, 'pr_number', 'notif-pr' }, { 3, 43, 'issue_number', 'notif-issue' } }) do
    local ctx = context(status, case[1], 15)
    local expected = { repo = repo, number = case[2], [case[3]] = case[2], notification_id = case[4] }
    fields(ctx, expected)
    eq(ctx.target, expected)
  end
end)

test('PR-scoped job logs use bufkey job and cached run/workflow', function()
  local buf = buffer('prlogs', repo, 456, { 'Tests passed' }, { id = 42 })
  local ctx = context(buf)
  fields(
    ctx,
    { pr_number = 42, pr = pr_data, job = job, job_id = 456, run_id = 123, workflow_id = 789, workflow_name = 'Checks' }
  )
end)

test('commit-scoped job logs never infer PR number', function()
  local commit_job = { databaseId = 457, runId = 124, name = 'Build: compile' }
  local buf = buffer('prlogs', repo, 457, { 'Build passed' }, { id = sha, ci_sha = sha, ci_jobs = { commit_job } })
  local ctx = context(buf)
  fields(ctx, { sha = sha, job_id = 457, run_id = 124, workflow_name = 'Build', job = commit_job })
  absent(ctx, { 'number', 'pr_number', 'pr', 'workflow_id' })
end)

test('GraphQL CI jobs extract workflow identity and log snapshots expose it', function()
  local jobs = require('guh.gh')._to_ci_jobs({
    headCommit = {
      nodes = {
        {
          commit = {
            statusCheckRollup = {
              contexts = {
                nodes = {
                  {
                    __typename = 'CheckRun',
                    name = 'tests',
                    conclusion = 'SUCCESS',
                    status = 'COMPLETED',
                    startedAt = '2026-01-01T00:00:00Z',
                    detailsUrl = 'https://github.com/o/r/actions/runs/321/job/654',
                    checkSuite = {
                      app = { slug = 'github-actions' },
                      workflowRun = { workflow = { name = 'CI', databaseId = 456 } },
                    },
                  },
                },
              },
            },
          },
        },
      },
    },
  })
  eq(#jobs, 1)
  fields(jobs[1], {
    databaseId = 654,
    runId = 321,
    workflowId = 456,
    workflowName = 'CI',
    name = 'CI: tests',
    conclusion = 'success',
    status = 'completed',
  })
  -- A saved ci_job remains authoritative even when the parent cache/list is
  -- missing or stale (including a preloaded log with no content yet).
  for _, commit_scoped in ipairs({ false, true }) do
    local owner = commit_scoped and 'commit/logs' or repo
    local buf = buffer('prlogs', owner, 654, { '' }, {
      id = commit_scoped and sha or 42,
      ci_sha = commit_scoped and sha or vim.NIL,
      ci_job = jobs[1],
      ci_jobs = {},
    })
    local ctx = context(buf)
    fields(ctx, { job = jobs[1], job_id = 654, run_id = 321, workflow_id = 456, workflow_name = 'CI' })
    if commit_scoped then
      eq(ctx.sha, sha)
      absent(ctx, { 'number', 'pr_number', 'pr' })
    else
      eq(ctx.pr_number, 42)
    end
    ctx.job.workflowName = 'mutated'
    eq(context(buf).workflow_name, 'CI')
    eq(context(buf).job.workflowName, 'CI')
  end
end)

test('plain numeric cursor tokens are not references', function()
  local buf = buffer('issue', repo, 80, { 'Count 123', '123' })
  for _, pos in ipairs({ { 1, 7 }, { 2, 0 } }) do
    local ctx = context(buf, pos[1], pos[2])
    fields(ctx, { number = 80, issue_number = 80 })
    absent(ctx, { 'target', 'pr_number' })
  end
end)

test('punctuated numbers are not explicit PR references', function()
  local buf = buffer('repo', repo, 'all', { 'Open PRs:', '  #45  Fix (123)', '  #45  Fix 123,' })
  for row = 2, 3 do
    fields(context(buf, row, 12), { pr_number = 45, number = 45 })
  end
end)

test('PR body SHA-shaped rows do not implicitly select a commit', function()
  local buf = buffer('pr', repo, 84, { 'deadbeef  example value', '## Discussion', 'abcdef0  other value' })
  eq(context(buf, 1, 20).target, nil)
  eq(context(buf, 3, 15).target, nil)
  eq(context(buf, 1, 2).sha, 'deadbeef') -- Explicit cursor reference still works.
end)

test('unrelated links cannot associate a commit buffer with a PR', function()
  local commit_sha = string.rep('c', 40)
  local buf = buffer('commit', repo, commit_sha, { 'https://github.com/o/r/pull/42' }, { id = commit_sha })
  local ctx = context(buf)
  fields(ctx, { repo = repo, sha = commit_sha })
  absent(ctx, { 'number', 'pr_number', 'pr' })
  fields(ctx.target, { repo = repo, pr_number = 42 })
end)

test('linked same-repo subjects do not mix enclosing PR/issue identities', function()
  local cases = {
    {
      feat = 'pr',
      id = 81,
      url = 'issues/43',
      kind = 'pr_number',
      target_kind = 'issue_number',
      target_id = 43,
      notification_id = 'notif-issue',
    },
    {
      feat = 'issue',
      id = 82,
      url = 'pull/42',
      kind = 'issue_number',
      target_kind = 'pr_number',
      target_id = 42,
      notification_id = 'notif-pr',
    },
  }
  for _, case in ipairs(cases) do
    local buf = buffer(case.feat, repo, case.id, { 'See https://github.com/o/r/' .. case.url })
    local ctx = context(buf, 1, 12)
    fields(ctx, { repo = repo, number = case.id, [case.kind] = case.id })
    absent(ctx, { case.target_kind, 'notification_id' })
    eq(ctx.target, {
      repo = repo,
      number = case.target_id,
      [case.target_kind] = case.target_id,
      notification_id = case.notification_id,
    })
  end
end)

test('issue edit buffers preserve subject kind through nested edits', function()
  local issue = buffer('issue', repo, 83, { 'Issue body' })
  context(issue)
  local function submitted()
    error('test must not submit a comment')
  end
  comments.edit_comment('comment', 83, { 'Draft comment' }, nil, submitted)
  local edit = vim.api.nvim_get_current_buf()
  eq(state.get_b_guh(edit).subject_kind, 'issue')
  fields(context(edit), { number = 83, issue_number = 83 })
  absent(context(edit), { 'pr_number', 'pr' })
  comments.edit_comment('review', 83, { 'Nested draft' }, nil, submitted)
  local nested = vim.api.nvim_get_current_buf()
  eq(state.get_b_guh(nested).subject_kind, 'issue')
  fields(context(nested), { number = 83, issue_number = 83 })
  absent(context(nested), { 'pr_number', 'pr' })
  -- No write/submit, and suppress abort notifications during test shutdown.
  vim.bo[edit].modified = false
  vim.bo[nested].modified = false
end)

test('action URLs retain run/job and numeric or filename workflow IDs', function()
  local cases = {
    { 'runs/123/job/456', { run_id = 123, job_id = 456 } },
    { 'runs/123', { run_id = 123 } },
    { 'workflows/789', { workflow_id = 789 } },
    { 'workflows/checks.yml?query=branch:main', { workflow_id = 'checks.yml' } },
  }
  local lines = {}
  for _, case in ipairs(cases) do
    lines[#lines + 1] = 'See https://github.com/o/r/actions/' .. case[1]
  end
  local buf = buffer('issue', repo, 70, lines)
  for row, case in ipairs(cases) do
    local ctx = context(buf, row, 12)
    local expected = vim.tbl_extend('force', { repo = repo }, case[2])
    eq(ctx.target, expected)
    fields(ctx, { number = 70, issue_number = 70 })
    fields(ctx, expected)
    absent(ctx.target, { 'number', 'pr_number', 'issue_number' })
  end
end)

test('log URIs carry job IDs rather than interpreting them as PR numbers', function()
  local buf = buffer('issue', repo, 71, { 'guh://o/r/prlogs/654', 'guh://o/r/prlogs/987' })
  local ctx = context(buf)
  fields(ctx, { issue_number = 71, number = 71 })
  fields(ctx.target, { repo = repo, job_id = 654, run_id = 321, workflow_id = 456, pr_number = 42, number = 42 })
  eq(ctx.pr_number, nil)
  ctx = context(buf, 2)
  fields(ctx.target, { repo = repo, job_id = 987 })
  absent(ctx.target, { 'number', 'pr_number' })
end)

test('comment URL anchors identify referenced comments', function()
  local buf = buffer('pr', repo, 72, {
    'https://github.com/o/r/pull/72#discussion_r111',
    'https://github.com/o/r/issues/43#issuecomment-222',
  })
  fields(context(buf), { pr_number = 72, comment_id = 111 })
  fields(context(buf).target, { pr_number = 72, comment_id = 111 })
  local ctx = context(buf, 2)
  fields(ctx.target, { issue_number = 43, comment_id = 222 })
  absent(ctx, { 'issue_number', 'comment_id' })
end)

test('ambiguous SHA prefixes are not expanded to an arbitrary commit', function()
  local buf = buffer('pr', repo, 73, { '## Commits (2)', 'abcdef0  message' }, {
    pr_data = {
      number = 73,
      commits = { { oid = sha }, { oid = 'abcdef0' .. string.rep('0', 33) } },
    },
  })
  eq(context(buf, 2, 10).sha, 'abcdef0')
  state.set_b_key(buf, { 'guh', 'pr_data' }, vim.NIL)
end)

test('cross-repo reference stays only in target', function()
  local ctx = context(pr, 4, 10)
  eq(ctx.target, { repo = 'elsewhere/project', number = 99 })
  fields(ctx, { repo = repo, number = 42, pr_number = 42, pr = pr_data, notification_id = 'notif-pr' })
  eq(ctx.issue_number, nil)
end)

test('file SHA and nested path come from bufkey', function()
  local buf = buffer('file', repo, sha .. '/src/nested/main.lua', { 'first', 'second' }, { id = 42 })
  fields(
    context(buf, 2, 2),
    { repo = repo, pr_number = 42, sha = sha, path = 'src/nested/main.lua', line = 2, new_line = 2, side = 'RIGHT' }
  )
end)

local diff_lines = {
  'diff --git a/src/main.lua b/src/main.lua', -- 1
  'index 1111111..2222222 100644',
  '--- a/src/main.lua',
  '+++ b/src/main.lua',
  '@@ -10,3 +20,3 @@', -- 5
  ' unchanged', -- 6: old 10, new 20
  '-removed', -- 7: old 11
  '+added', -- 8: new 21
  ' trailing', -- 9: old 12, new 22
  '(viewed) docs/readme.md', -- 10
  'diff --git a/deleted.lua b/deleted.lua', -- 11
  'deleted file mode 100644',
  '--- a/deleted.lua',
  '+++ /dev/null',
  '@@ -3,1 +0,0 @@',
  '-gone', -- 16: old 3
  'diff --git a/outdated-77:old.lua b/outdated-77:old.lua',
  '--- a/outdated-77:old.lua',
  '+++ b/outdated-77:old.lua',
  '@@ -5,1 +6,1 @@',
  '+stale', -- 21
}
local diff = buffer('prdiff', repo, 42, diff_lines)

test('diff headers have paths but no bogus source line', function()
  for _, row in ipairs({ 1, 2, 3, 4, 5, 11, 12, 13, 14, 15 }) do
    local ctx = context(diff, row)
    eq(ctx.path, row < 11 and 'src/main.lua' or 'deleted.lua')
    absent(ctx, { 'line', 'old_line', 'new_line', 'side' })
  end
end)

test('diff addition deletion and context axes', function()
  local cases = {
    { row = 6, old_line = 10, new_line = 20, line = 20, side = 'RIGHT' },
    { row = 7, old_line = 11, line = 11, side = 'LEFT' },
    { row = 8, new_line = 21, line = 21, side = 'RIGHT' },
    { row = 9, old_line = 12, new_line = 22, line = 22, side = 'RIGHT' },
    { row = 16, old_line = 3, line = 3, side = 'LEFT' },
  }
  for _, case in ipairs(cases) do
    local ctx = context(diff, case.row)
    fields(ctx, case)
    eq(ctx.old_line, case.old_line)
    eq(ctx.new_line, case.new_line)
    eq(ctx.path, case.row == 16 and 'deleted.lua' or 'src/main.lua')
  end
end)

test('viewed and quasi paths', function()
  local ctx = context(diff, 10)
  eq(ctx.path, 'docs/readme.md')
  absent(ctx, { 'line', 'old_line', 'new_line', 'side' })
  fields(context(diff, 21), { path = 'old.lua', quasi = 'outdated', new_line = 6, line = 6, side = 'RIGHT' })
end)

test('commit patch context and unambiguous same-repo PR association', function()
  local buf = buffer('commit', repo, sha, diff_lines, { id = sha })
  fields(
    context(buf, 7),
    { sha = sha, pr_number = 42, pr = pr_data, path = 'src/main.lua', old_line = 11, side = 'LEFT' }
  )
  local foreign = buffer('pr', 'foreign/repo', 42, { 'Foreign PR' }, { pr_data = pr_data })
  eq(context(buf, 7).pr_number, 42)
  local other = buffer(
    'pr',
    repo,
    44,
    { 'Another PR' },
    { pr_data = vim.tbl_extend('force', pr_data, { number = 44 }) }
  )
  absent(context(buf, 7), { 'pr_number', 'pr', 'base_sha', 'head_sha' })
  state.set_b_key(other, { 'guh', 'pr_data' }, vim.NIL)
  state.set_b_key(pr, { 'guh', 'pr_data' }, vim.NIL)
  absent(context(buf, 7), { 'pr_number', 'pr' }) -- Foreign cache alone must not associate.
  state.set_b_key(pr, { 'guh', 'pr_data' }, pr_data)
  assert(vim.api.nvim_buf_is_valid(foreign))
end)

test('real comment renderer maps diagnostic ranges and individual rendered comments', function()
  local first = {
    id = 1001,
    thread_id = 77,
    thread_node_id = 'THREAD_77',
    user = 'alice',
    body = 'Please adjust\nthis line',
    path = 'src/main.lua',
    side = 'RIGHT',
    end_line = 21,
  }
  local reply = vim.tbl_extend('force', first, { id = 1002, body = 'Agreed', user = 'bob' })
  local stale = vim.tbl_extend('force', first, { id = 1003, path = 'outdated-77:old.lua', end_line = 6 })
  local cb = comments.load_pr_comments(42, repo, diff, pr_data, {
    ['src/main.lua'] = { { start_line = 20, end_line = 21, comments = { first, reply } } },
    ['outdated-77:old.lua'] = { { start_line = 6, end_line = 6, comments = { stale } } },
  })
  for _, row in ipairs({ 6, 7, 8 }) do
    local ctx = context(diff, row)
    eq(#ctx.comments, 2)
    eq(ctx.comments[1].id, 1001)
    eq(ctx.comments[2].id, 1002)
    fields(ctx, { thread_id = 77, thread_node_id = 'THREAD_77' })
    absent(ctx, { 'comment', 'comment_id' })
  end
  eq(context(diff, 9).comments, nil) -- End is inclusive, but not the next row.
  local rows = state.get_b_guh(cb).comment_rows
  local seen = {}
  for row, comment in pairs(rows) do
    local ctx = context(cb, tonumber(row))
    fields(ctx, {
      comment_id = comment.id,
      comment = comment,
      thread_id = 77,
      thread_node_id = 'THREAD_77',
      side = 'RIGHT',
      line = comment.end_line,
    })
    eq(#ctx.comments, 1)
    eq(ctx.path, comment.id == 1003 and 'old.lua' or 'src/main.lua')
    eq(ctx.quasi, comment.id == 1003 and 'outdated' or nil)
    seen[comment.id] = true
  end
  eq(seen, { [1001] = true, [1002] = true, [1003] = true })
  eq(context(cb, 1).comment, nil)
  fields(context(diff, 21), { comment_id = 1003, thread_id = 77, path = 'old.lua', quasi = 'outdated' })
  vim.api.nvim_buf_set_lines(cb, 0, 0, false, { 'manually inserted' })
  for row in pairs(rows) do
    absent(context(cb, tonumber(row)), { 'comment', 'comments', 'comment_id', 'thread_id' })
  end
end)

test('snapshots detach nested PR, job, target and comments', function()
  local ctx = context(pr, 2, 9)
  ctx.pr.commits[1].oid = 'changed'
  ctx.pr.ci_jobs[1].name = 'changed'
  ctx.target.sha = 'changed'
  local fresh = context(pr, 2, 9)
  eq(fresh.pr, pr_data)
  eq(fresh.target.sha, sha)
  local logbuf = state.get_buf('prlogs', repo, 456, false)
  local logctx = context(logbuf)
  logctx.job.name = 'changed'
  eq(context(logbuf).job, job)
  local commentctx = context(diff, 21)
  commentctx.comment.body = 'changed'
  commentctx.comments[1].thread_node_id = 'changed'
  local again = context(diff, 21)
  eq(again.comment.body, 'Please adjust\nthis line')
  eq(again.comments[1].thread_node_id, 'THREAD_77')
end)

for _, failure in ipairs(failures) do
  io.stderr:write(failure .. '\n')
end
print(('%d context tests passed; %d failed'):format(passed, #failures))
if #failures > 0 then
  vim.cmd('cquit 1')
end
