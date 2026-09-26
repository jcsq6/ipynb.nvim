-- Scrolling tests: the edit overlay over tall cells, and tall outputs
-- Run with: nvim --headless -u tests/minimal_init.lua -l tests/test_scroll.lua

local h = require('tests.helpers')
local cells_mod = require('ipynb.cells')
local config = require('ipynb.config')

print('')
print(string.rep('=', 60))
print('Running scroll tests')
print(string.rep('=', 60))
print('')

---Write a notebook: a short cell, a tall cell, a short cell with a long output
---@return string path
local function tall_notebook(tall_lines, output_lines)
  local tall = {}
  for i = 1, tall_lines do
    table.insert(tall, 'line_' .. i .. ' = ' .. i .. (i < tall_lines and '\n' or ''))
  end
  local out = {}
  for i = 1, output_lines do
    table.insert(out, 'out ' .. i .. '\n')
  end
  local nb = {
    cells = {
      { cell_type = 'code', id = 'short', metadata = {}, source = { 'a = 1' }, outputs = {}, execution_count = vim.NIL },
      { cell_type = 'code', id = 'tall', metadata = {}, source = tall, outputs = {}, execution_count = vim.NIL },
      {
        cell_type = 'code', id = 'noisy', metadata = {}, source = { 'print(1)' }, execution_count = 1,
        outputs = { { output_type = 'stream', name = 'stdout', text = out } },
      },
    },
    metadata = { kernelspec = { name = 'python3', display_name = 'Python 3', language = 'python' } },
    nbformat = 4,
    nbformat_minor = 5,
  }
  local path = vim.fn.tempname() .. '.ipynb'
  vim.fn.writefile({ vim.json.encode(nb) }, path)
  return path
end

---Move the overlay cursor to a line of the edited cell and let it sync
local function move_in_cell(line)
  local state = h.get_state()
  vim.api.nvim_win_set_cursor(state.edit_state.win, { line, 0 })
  vim.api.nvim_exec_autocmds('CursorMoved', { buffer = state.edit_state.buf })
  vim.wait(50)
end

---Check the overlay covers exactly the visible part of the cell
local function assert_overlay_mirrors_facade()
  local state = h.get_state()
  local edit = state.edit_state
  local parent_info = vim.fn.getwininfo(edit.parent_win)[1]
  local float_info = vim.fn.getwininfo(edit.win)[1]
  local w0 = parent_info.topline - 1

  h.assert_true(float_info.height <= parent_info.height,
    string.format('Overlay (%d rows) must fit in the notebook window (%d rows)', float_info.height, parent_info.height))
  local first = math.max(edit.start_line, w0)
  h.assert_eq(float_info.topline, first - edit.start_line + 1, 'Overlay should show the first visible cell line')
  local float_cursor = vim.api.nvim_win_get_cursor(edit.win)[1]
  local parent_cursor = vim.api.nvim_win_get_cursor(edit.parent_win)[1]
  h.assert_eq(parent_cursor, edit.start_line + float_cursor, 'Notebook cursor should follow the overlay cursor')
end

h.run_test('overlay_over_tall_cell_fits_window', function()
  local path = tall_notebook(80, 2)
  h.open_notebook_path(path)
  h.enter_cell(2)
  assert_overlay_mirrors_facade()

  for _, line in ipairs({ 20, 45, 79, 10, 1 }) do
    move_in_cell(line)
    assert_overlay_mirrors_facade()
  end
  vim.fn.delete(path)
end)

h.run_test('scroll_commands_scroll_the_notebook', function()
  local path = tall_notebook(80, 2)
  h.open_notebook_path(path)
  h.enter_cell(2)
  local state = h.get_state()
  local edit_mod = require('ipynb.edit')

  local top_before = vim.fn.getwininfo(state.edit_state.parent_win)[1].topline
  edit_mod.scroll_notebook(state, '<C-d>')
  local top_after = vim.fn.getwininfo(state.edit_state.parent_win)[1].topline
  h.assert_true(top_after > top_before, 'Notebook should scroll down')
  h.assert_true(h.is_in_edit_float(), 'Still editing while the cursor is in the cell')
  assert_overlay_mirrors_facade()
  vim.fn.delete(path)
end)

h.run_test('scrolling_past_the_cell_leaves_cell_mode', function()
  local path = tall_notebook(10, 2)
  h.open_notebook_path(path)
  h.enter_cell(1)
  local state = h.get_state()
  local facade_buf = state.facade_buf
  require('ipynb.edit').scroll_notebook(state, '20<C-e>')
  vim.wait(50)
  h.assert_false(h.is_in_edit_float(), 'Scrolling the cell off screen should close the overlay')
  h.assert_eq(vim.api.nvim_get_current_buf(), facade_buf, 'Focus should be back on the notebook')
  vim.fn.delete(path)
end)

---Virtual lines rendered under a cell's output
local function output_virt_lines(state, cell_idx)
  local _, end_line = cells_mod.get_cell_range(state, cell_idx)
  local ns = vim.api.nvim_get_namespaces()['notebook_outputs']
  local marks = vim.api.nvim_buf_get_extmarks(state.facade_buf, ns, { end_line, 0 }, { end_line, -1 }, { details = true })
  h.assert_eq(#marks, 1, 'Expected one output extmark')
  return marks[1][4].virt_lines
end

h.run_test('tall_output_is_cut_to_fit_window', function()
  local path = tall_notebook(3, 200)
  local state = h.open_notebook_path(path)
  local output_mod = require('ipynb.output')
  local max = output_mod.max_output_lines(state)
  h.assert_true(max < vim.api.nvim_win_get_height(0), 'Output cap should be below the window height')

  local lines = output_virt_lines(state, 3)
  h.assert_eq(#lines, max, 'Output should use exactly the cap')
  local footer = lines[#lines][1][1]
  h.assert_true(footer:match('more lines'), 'Last row should say how much was cut: ' .. footer)
  -- separator + shown text lines + footer
  h.assert_true(footer:match('^… ' .. (200 - (max - 2)) .. ' more'), 'Footer should count hidden lines: ' .. footer)
  vim.fn.delete(path)
end)

h.run_test('output_cap_can_be_disabled', function()
  local previous = config.get().output
  config.get().output = { max_lines = false }
  local path = tall_notebook(3, 200)
  local ok, err = pcall(function()
    local state = h.open_notebook_path(path)
    h.assert_eq(#output_virt_lines(state, 3), 201, 'Separator plus every output line')
  end)
  config.get().output = previous
  vim.fn.delete(path)
  assert(ok, err)
end)

h.run_test('short_output_is_not_cut', function()
  local path = tall_notebook(3, 4)
  local state = h.open_notebook_path(path)
  h.assert_eq(#output_virt_lines(state, 3), 5, 'Separator plus 4 lines, no footer')
  vim.fn.delete(path)
end)

local success = h.summary()
vim.cmd(success and 'qa!' or 'cq!')
