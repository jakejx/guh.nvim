local comments = require('guh.comments')
local state = require('guh.state')
local util = require('guh.util')

local M = {}

-- Only infer a PR/issue kind when local data actually establishes it.
local function identify(target, id, is_pr)
  target.number = id
  if is_pr ~= nil then
    target[is_pr and 'pr_number' or 'issue_number'] = id
  end
end

local function notification(target, notifications)
  if not target.repo or not target.number then
    return
  end
  local n = (notifications or {})[('%s#%s'):format(target.repo, target.number)]
  if n then
    target.notification_id = n.thread_id
    identify(target, target.number, n.is_pr)
  end
end

local function cached_kind(target)
  if not target.repo or not target.number or target.pr_number or target.issue_number then
    return
  end
  if state.get_buf('pr', target.repo, target.number, false) then
    identify(target, target.number, true)
  elseif state.get_buf('issue', target.repo, target.number, false) then
    identify(target, target.number, false)
  end
end

local function add_pr(ctx, pr)
  if pr then
    ctx.pr = pr
    ctx.base_sha, ctx.head_sha = pr.baseRefOid, pr.headRefOid
    ctx.base_branch, ctx.head_branch = pr.baseRefName, pr.headRefName
  end
end

local function add_job(ctx, job)
  ctx.job = job
  ctx.job_id = job.databaseId
  ctx.run_id = job.runId
  ctx.workflow_name = job.workflowName or (job.name or ''):match('^(.-): ')
  ctx.workflow_id = job.workflowId
end

-- Actions URLs are not PR/issue targets; don't let parse_target's repo fallback
-- turn them into plain repositories. Workflow identifiers may be a filename.
local function parse_token(token, repo)
  -- A line number, timestamp, or numeric source literal is not a PR reference.
  if token:match('^%d+$') then
    return nil
  end
  local owner, name, job_id = token:match('guh://([%w._-]+)/([%w._-]+)/prlogs/(%d+)')
  if owner then
    local target = { repo = owner .. '/' .. name, job_id = tonumber(job_id) }
    local log = state.get_buf('prlogs', target.repo, target.job_id, false)
    local lb = log and state.get_b_guh(log)
    if lb then
      if lb.ci_sha then
        target.sha = lb.ci_sha
      else
        identify(target, tonumber(lb.id), true)
      end
      if lb.ci_job then
        add_job(target, lb.ci_job)
      end
    end
    return target
  end
  local rest
  owner, name, rest = token:match('https?://github%.com/([%w._-]+)/([%w._-]+)/actions/([^%s%)%]>]+)')
  if owner then
    local target = { repo = owner .. '/' .. name }
    local run, job = rest:match('^runs/(%d+)/job/(%d+)')
    target.run_id = tonumber(run or rest:match('^runs/(%d+)'))
    target.job_id = tonumber(job)
    local workflow = rest:match('^workflows/([^/?#]+)')
    target.workflow_id = workflow and (tonumber(workflow) or workflow)
    if target.run_id or target.workflow_id then
      return target
    end
    return nil
  end
  local parsed = util.parse_target(token)
  if not parsed or (parsed.id and not parsed.owner and not token:find('#', 1, true)) then
    return nil
  end
  if parsed.status then
    return { status = true }
  end
  local target = {
    repo = parsed.owner and (parsed.owner .. '/' .. parsed.repo) or repo,
    sha = parsed.sha,
    branch = parsed.branch,
    comment_id = tonumber(token:match('#discussion_r(%d+)') or token:match('#issuecomment%-(%d+)')),
  }
  if parsed.id then
    identify(target, parsed.id, parsed.is_pr)
  end
  if target.repo or target.sha or target.number or target.branch then
    return target
  end
end

local function cursor_token(line, col)
  local start = 1
  while true do
    local s, e = line:find('%S+', start)
    if not s then
      return nil
    end
    if col + 1 >= s and col + 1 <= e then
      return line:sub(s, e)
    end
    start = e + 1
  end
end

local function repo_row(lines, row, repo)
  local line = lines[row]
  local id = tonumber(line:match('^%s+#(%d+)%s'))
  if id then
    local is_pr
    for i = row - 1, 1, -1 do
      local heading = lines[i]
      if heading:match('^Open issues') then
        is_pr = false
        break
      elseif
        heading:match('^Open PRs')
        or heading:match('^Current branch')
        or heading:match('^Created by you')
        or heading:match('^Requesting a code review from you')
      then
        is_pr = true
        break
      end
    end
    local target = { repo = repo }
    identify(target, id, is_pr)
    return target
  end
  local first = line:match('^%s+(%S+)')
  if first and first:match('^%x+$') and #first >= 7 and #first <= 40 then
    for i = row - 1, 1, -1 do
      if lines[i]:match('^%S') then
        if lines[i]:match('^Recent commits:') then
          return { repo = repo, sha = first }
        end
        break
      end
    end
  end
  return first and parse_token(first, repo)
end

local function add_comment_context(ctx, cs)
  if #cs == 0 then
    return
  end
  ctx.comments = cs
  if #cs == 1 then
    ctx.comment = cs[1]
    ctx.comment_id = cs[1].id
  end
  local first = cs[1]
  local same_thread = true
  for _, c in ipairs(cs) do
    if c.thread_id ~= first.thread_id then
      same_thread = false
    end
  end
  if same_thread then
    ctx.thread_id = first.thread_id
    ctx.thread_node_id = first.thread_node_id
  end
end

function M.get()
  local buf = vim.api.nvim_get_current_buf()
  local b = state.get_b_guh(buf)
  if not b or not b.feat then
    return nil
  end
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local ctx = { bufnr = buf, feat = b.feat, row = row, col = col, repo = b.repo }
  local feat = b.feat
  if feat == 'issue' or b.subject_kind == 'issue' then
    identify(ctx, tonumber(b.id), false)
  elseif feat == 'commit' or b.ci_sha then
    ctx.sha = b.ci_sha or b.id
  elseif feat ~= 'repo' and feat ~= 'status' then
    identify(ctx, tonumber(b.id), true)
  end

  local pr = ctx.pr_number and state.get_pr_data(ctx.repo, ctx.pr_number)
  -- Commit views can be related to several PRs. Only expose an unambiguous,
  -- repository-scoped association; never borrow another repo's matching SHA.
  if feat == 'commit' then
    local matches = {}
    for _, pr_buf in pairs(state.bufs.pr) do
      local pb = state.get_b_guh(pr_buf)
      local data = pb and pb.pr_data
      if pb and pb.repo == ctx.repo and data then
        for _, commit in ipairs(data.commits or {}) do
          if commit.oid == ctx.sha then
            matches[#matches + 1] = data
            break
          end
        end
      end
    end
    if #matches == 1 then
      pr = matches[1]
      identify(ctx, pr.number, true)
    end
  end
  add_pr(ctx, pr)

  if feat == 'file' then
    local key = (b.bufkey or ''):sub(#(b.repo or '') + 2)
    ctx.sha, ctx.path = key:match('^([^/]+)/(.+)$')
    ctx.line, ctx.new_line, ctx.side = row, row, 'RIGHT'
  elseif feat == 'commit' or feat == 'prdiff' then
    for k, v in pairs(comments.get_diff_context(buf, row) or {}) do
      ctx[k] = v
    end
  elseif feat == 'prcomments' then
    local current = b.comment_rows_tick == vim.api.nvim_buf_get_changedtick(buf)
    local c = current and (b.comment_rows or {})[tostring(row)]
    if c then
      add_comment_context(ctx, { c })
      ctx.path = c.path:gsub('^outdated%-%d+:', ''):gsub('^outside%-%d+:', '')
      ctx.quasi = c.path:match('^(outdated)%-%d+:') or c.path:match('^(outside)%-%d+:')
      ctx.side, ctx.line = c.side or 'RIGHT', c.end_line
    end
  end
  if feat == 'prdiff' then
    local cs = {}
    local ns = vim.api.nvim_create_namespace('guh.comments')
    for _, d in ipairs(vim.diagnostic.get(buf, { namespace = ns })) do
      if row - 1 >= d.lnum and row - 1 < (d.end_lnum or d.lnum + 1) then
        vim.list_extend(cs, (d.user_data or {}).comments or {})
      end
    end
    add_comment_context(ctx, cs)
  elseif feat == 'prlogs' then
    ctx.job_id = tonumber((b.bufkey or ''):match('/(%d+)$'))
    if b.ci_job then
      add_job(ctx, b.ci_job)
    else
      for _, job in ipairs(b.ci_jobs or (pr and pr.ci_jobs) or {}) do
        if job.databaseId == ctx.job_id then
          add_job(ctx, job)
          break
        end
      end
    end
  end

  local target
  if feat == 'status' then
    local slug = lines[row]:match('^%s+(%S+#%d+)%s')
    target = slug and parse_token(slug)
    if target then
      notification(target, b.notifications)
    end
  elseif feat == 'repo' then
    target = repo_row(lines, row, b.repo)
  elseif feat == 'pr' then
    -- A commit row denotes the commit even with the cursor on its message.
    local sha = lines[row]:match('^(%x+)%s%s')
    if sha and #sha >= 7 and #sha <= 40 then
      for i = row - 1, 1, -1 do
        if lines[i]:match('^## ') then
          if lines[i]:match('^## Commits %(%d+%)$') then
            target = { repo = b.repo, sha = sha }
          end
          break
        end
      end
    end
  end
  -- Explicit cursor targets take priority over a row's implicit identity.
  local token = cursor_token(lines[row], col)
  local explicit = token and parse_token(token, b.repo)
  if explicit then
    -- Preserve the row's known PR/issue kind when cursor is on its number.
    if
      not target
      or explicit.repo ~= target.repo
      or explicit.number ~= target.number
      or explicit.sha ~= target.sha
      or explicit.branch ~= target.branch
      or explicit.run_id ~= target.run_id
      or explicit.job_id ~= target.job_id
      or explicit.workflow_id ~= target.workflow_id
      or explicit.comment_id ~= target.comment_id
    then
      target = explicit
    end
  end
  if target then
    cached_kind(target)
    local status = state.get_buf('status', nil, 'all', false)
    notification(target, status and state.get_b_key(status, { 'guh', 'notifications' }))
    if target.sha and target.repo == ctx.repo then
      local matches = {}
      for _, commit in ipairs((pr or {}).commits or {}) do
        if vim.startswith(commit.oid, target.sha) then
          matches[#matches + 1] = commit.oid
        end
      end
      if #matches == 1 then
        target.sha = matches[1]
      end
    end
    ctx.target = target
    -- Keep enclosing identities. Cross-repo references live only in target,
    -- preventing combinations like the current PR number with a foreign repo.
    if
      (not ctx.repo or ctx.repo == target.repo)
      and (not ctx.number or not target.number or ctx.number == target.number)
      and not (feat == 'commit' and target.number and not ctx.pr_number)
    then
      for k, v in pairs(target) do
        if ctx[k] == nil then
          ctx[k] = v
        end
      end
    end
  end
  if not ctx.pr and ctx.pr_number then
    add_pr(ctx, state.get_pr_data(ctx.repo, ctx.pr_number))
  end
  if ctx.number then
    local status = state.get_buf('status', nil, 'all', false)
    notification(ctx, status and state.get_b_key(status, { 'guh', 'notifications' }))
  end
  return vim.deepcopy(ctx)
end

return M
