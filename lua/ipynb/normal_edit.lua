-- ipynb/normal_edit.lua - Normal-mode edits made directly on the facade buffer
--
-- The facade is modifiable, so operators like dd, x, p, >> and . work on cell
-- content without opening the edit float. After each change the facade is
-- re-parsed: edits that keep the cell layout intact are synced into the cells,
-- the LSP shadow and the visuals; edits that break it (deleting a border line,
-- joining two cells, text between cells) are undone.

local M = {}

---@param a Cell[]
---@param b Cell[]
---@return boolean
local function same_cells(a, b)
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i].type ~= b[i].type or a[i].source ~= b[i].source then
      return false
    end
  end
  return true
end

---@param buf number
---@param lines string[]
local function set_lines(buf, lines)
  local ok, err = pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, lines)
  if not ok and err and not err:match('_changetracking') then
    error(err)
  end
end

---Re-place markers and re-render everything that hangs off the facade lines
---@param state NotebookState
local function refresh_views(state)
  require('ipynb.cells').place_markers(state)
  local lsp_mod = require('ipynb.lsp')
  lsp_mod.refresh_shadow(state)
  lsp_mod.refresh_facade_diagnostics(state)

  -- Deferred like global undo/redo to avoid the signcols race
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(state.facade_buf) then
      return
    end
    require('ipynb.visuals').render_all(state)
    require('ipynb.output').render_all(state)
    local images_mod = require('ipynb.images')
    if images_mod.is_available() then
      images_mod.sync_positions(state)
    end
  end)
end

---Run fn in every window showing buf, restoring each window's cursor after
---@param buf number
---@param fn function
local function keeping_cursors(buf, fn)
  local cursors = {}
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    cursors[win] = vim.api.nvim_win_get_cursor(win)
  end
  fn()
  local line_count = vim.api.nvim_buf_line_count(buf)
  for win, cursor in pairs(cursors) do
    pcall(vim.api.nvim_win_set_cursor, win, { math.min(cursor[1], line_count), cursor[2] })
  end
end

---Undo a change that broke the cell layout
---@param state NotebookState
local function revert(state)
  local buf = state.facade_buf
  local io_mod = require('ipynb.io')
  local expected = io_mod.cells_to_jupytext(state.cells)

  vim.api.nvim_buf_call(buf, function()
    vim.cmd('silent! undo')
  end)
  if not vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), expected) then
    -- The change wasn't a single undo step; rebuild the facade from the cells
    keeping_cursors(buf, function()
      set_lines(buf, expected)
    end)
  end

  refresh_views(state)
  vim.notify('ipynb: that edit would break cell boundaries, so it was undone', vim.log.levels.WARN)
end

---Sync the facade into the notebook after a normal-mode change
---@param state NotebookState
---@return boolean accepted false if the change was reverted
function M.sync(state)
  local buf = state.facade_buf
  -- While the edit float is open it owns the facade; edit.lua syncs it
  if state.edit_state or state.skip_sync or not buf or not vim.api.nvim_buf_is_valid(buf) then
    return true
  end

  local io_mod = require('ipynb.io')
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local parsed = io_mod.parse_facade_strict(lines)
  if not parsed then
    revert(state)
    return false
  end

  local canonical = io_mod.cells_to_jupytext(parsed)
  local layout_ok = vim.deep_equal(canonical, lines)
  if layout_ok and same_cells(parsed, state.cells) then
    return true -- Nothing new (e.g. a change the plugin already synced)
  end

  if not layout_ok then
    -- Cells are intact but spacing is off, e.g. a cell's last line was deleted
    -- (a cell always shows at least one line) or a separator line was removed.
    -- Fold the fix into the same undo step as the user's change.
    keeping_cursors(buf, function()
      vim.api.nvim_buf_call(buf, function()
        pcall(vim.cmd.undojoin)
        set_lines(buf, canonical)
      end)
    end)
  end

  require('ipynb.cells').sync_cells_from_facade(state)
  refresh_views(state)
  return true
end

---Setup autocmds that route normal-mode facade edits
---@param state NotebookState
function M.setup(state)
  local buf = state.facade_buf
  local group = vim.api.nvim_create_augroup('NotebookNormalEdit_' .. buf, { clear = true })

  vim.api.nvim_create_autocmd('TextChanged', {
    group = group,
    buffer = buf,
    callback = function()
      M.sync(state)
    end,
    desc = 'Sync normal-mode edits on the notebook facade',
  })

  -- i/a/o/... are mapped to open the edit float, but c, s, C, S, R and gi
  -- insert directly in the facade. That keeps typeahead, macros and . repeat
  -- working; the result is validated once Insert mode ends.
  vim.api.nvim_create_autocmd('InsertLeave', {
    group = group,
    buffer = buf,
    callback = function()
      M.sync(state)
    end,
    desc = 'Sync Insert-mode edits made on the notebook facade',
  })
end

return M
