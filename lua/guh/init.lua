local M = {}

--- Returns a detached, best-effort snapshot of the current Guh buffer and cursor.
--- Never fetches data, changes the cursor, or opens buffers. Nil outside Guh.
--- @return GuhContext?
function M.get_context()
  return require('guh.context').get()
end

return M
