-- Normal-mode editing on the notebook facade
-- Run with: nvim --headless -u tests/minimal_init.lua -l tests/test_normal_edit.lua

local h = require('tests.helpers')
local cells_mod = require('ipynb.cells')
local io_mod = require('ipynb.io')

print('')
print(string.rep('=', 60))
print('Running normal-mode facade edit tests')
print(string.rep('=', 60))
print('')

-- three_cells.ipynb: "# Cell 1\na = 1", "# Cell 2\nb = 2", "# Cell 3\nc = 3"

---Put the facade cursor on a line of a cell (0 = start marker, 1 = first content line)
local function goto_cell_line(cell_idx, offset, col)
  local state = h.get_state()
  local start = cells_mod.get_cell_range(state, cell_idx)
  vim.api.nvim_win_set_cursor(0, { start + offset + 1, col or 0 })
end

---Run normal-mode keys on the facade the way a user would
local function normal(keys)
  local state = h.get_state()
  h.feedkeys(keys)
  -- Headless feedkeys doesn't always reach the main loop's TextChanged check;
  -- firing it again is harmless because sync is idempotent.
  vim.api.nvim_exec_autocmds('TextChanged', { buffer = state.facade_buf })
  vim.wait(20)
end

local function sources()
  local out = {}
  for _, cell in ipairs(h.get_state().cells) do
    table.insert(out, cell.source)
  end
  return out
end

local function assert_same(actual, expected, msg)
  if not vim.deep_equal(actual, expected) then
    error((msg and msg .. ': ' or '') .. 'Expected ' .. vim.inspect(expected) .. ' but got ' .. vim.inspect(actual))
  end
end

local function assert_facade_canonical()
  local state = h.get_state()
  local lines = vim.api.nvim_buf_get_lines(state.facade_buf, 0, -1, false)
  h.assert_true(io_mod.parse_facade_strict(lines) ~= nil, 'Facade should have intact cell boundaries')
  h.assert_eq(table.concat(lines, '\n'), table.concat(io_mod.cells_to_jupytext(state.cells), '\n'),
    'Facade should match the cells')
end

h.run_test('facade_is_modifiable', function()
  local state = h.open_notebook('three_cells.ipynb')
  h.assert_true(vim.bo[state.facade_buf].modifiable, 'Facade should be modifiable')
end)

h.run_test('dd_deletes_line_in_cell', function()
  h.open_notebook('three_cells.ipynb')
  goto_cell_line(2, 2)
  normal('dd')
  assert_same(sources(), { '# Cell 1\na = 1', '# Cell 2', '# Cell 3\nc = 3' })
  assert_facade_canonical()
end)

h.run_test('x_deletes_char_in_cell', function()
  h.open_notebook('three_cells.ipynb')
  goto_cell_line(1, 2)
  normal('x')
  assert_same(sources()[1], '# Cell 1\n = 1')
end)

h.run_test('yank_paste_within_cells', function()
  h.open_notebook('three_cells.ipynb')
  goto_cell_line(1, 2)
  normal('yy')
  goto_cell_line(3, 2)
  normal('p')
  assert_same(sources()[3], '# Cell 3\nc = 3\na = 1')
  assert_facade_canonical()
end)

h.run_test('dd_on_cell_border_cuts_cell', function()
  h.open_notebook('three_cells.ipynb')
  goto_cell_line(2, 0)
  normal('dd')
  vim.wait(50) -- cell ops run scheduled from the expr mapping
  assert_same(sources(), { '# Cell 1\na = 1', '# Cell 3\nc = 3' })
  assert_facade_canonical()
  goto_cell_line(1, 0)
  normal('p')
  vim.wait(50)
  assert_same(sources(), { '# Cell 1\na = 1', '# Cell 2\nb = 2', '# Cell 3\nc = 3' })
end)

h.run_test('editing_cell_border_is_reverted', function()
  h.open_notebook('three_cells.ipynb')
  local before = sources()
  goto_cell_line(2, 0)
  normal('x')
  assert_same(sources(), before, 'Cells should be unchanged')
  assert_facade_canonical()
end)

h.run_test('redo_after_rejected_edit_keeps_cells', function()
  h.open_notebook('three_cells.ipynb')
  local before = sources()
  goto_cell_line(2, 0)
  normal('x')
  normal('<C-r>')
  assert_same(sources(), before, 'Redo must not restore the rejected edit')
  assert_facade_canonical()
end)

h.run_test('delete_across_cells_is_reverted', function()
  h.open_notebook('three_cells.ipynb')
  local before = sources()
  goto_cell_line(1, 2)
  normal('2j') -- sanity: motion alone changes nothing
  goto_cell_line(1, 2)
  normal('d2j')
  assert_same(sources(), before, 'Cells should be unchanged')
  assert_facade_canonical()
end)

h.run_test('join_into_border_is_reverted', function()
  h.open_notebook('three_cells.ipynb')
  local before = sources()
  goto_cell_line(1, 2)
  normal('J')
  assert_same(sources(), before, 'Cells should be unchanged')
  assert_facade_canonical()
end)

h.run_test('deleting_last_line_leaves_empty_cell', function()
  h.open_notebook('three_cells.ipynb')
  goto_cell_line(1, 1)
  normal('2dd')
  assert_same(sources(), { '', '# Cell 2\nb = 2', '# Cell 3\nc = 3' })
  h.assert_eq(#h.get_state().cells, 3, 'Cell should remain')
  assert_facade_canonical()
end)

h.run_test('undo_restores_normal_mode_edit', function()
  h.open_notebook('three_cells.ipynb')
  local before = sources()
  goto_cell_line(2, 2)
  normal('dd')
  assert_same(sources()[2], '# Cell 2')
  normal('u')
  assert_same(sources(), before)
  assert_facade_canonical()
end)

h.run_test('change_word_inserts_in_facade', function()
  h.open_notebook('three_cells.ipynb')
  goto_cell_line(1, 2)
  normal('cwzz<Esc>')
  vim.api.nvim_exec_autocmds('InsertLeave', { buffer = h.get_state().facade_buf })
  assert_same(sources()[1], '# Cell 1\nzz = 1')
  h.assert_false(h.is_in_edit_float(), 'Should stay on the facade')
  assert_facade_canonical()
end)

h.run_test('dot_repeat_works', function()
  h.open_notebook('three_cells.ipynb')
  goto_cell_line(1, 2)
  normal('cwzz<Esc>')
  goto_cell_line(2, 2)
  normal('.')
  assert_same(sources()[2], '# Cell 2\nzz = 2')
end)

h.run_test('edit_float_sees_normal_mode_edit', function()
  h.open_notebook('three_cells.ipynb')
  goto_cell_line(1, 2)
  normal('dd')
  h.enter_cell(1)
  h.assert_eq(h.get_edit_buffer_content(), '# Cell 1')
  h.exit_cell()
end)

h.run_test('outputs_survive_normal_mode_edit', function()
  local state = h.open_notebook('three_cells.ipynb')
  local id = state.cells[2].id
  state.cells[2].outputs = { { output_type = 'stream', name = 'stdout', text = 'hi\n' } }
  goto_cell_line(2, 2)
  normal('x')
  state = h.get_state()
  h.assert_eq(state.cells[2].id, id, 'Cell id should be kept')
  h.assert_eq(#state.cells[2].outputs, 1, 'Outputs should be kept')
end)

h.run_test('register_and_count_apply_to_paste_in_cell', function()
  h.open_notebook('three_cells.ipynb')
  vim.fn.setreg('a', 'z', 'v')
  goto_cell_line(1, 2)
  normal('"a2p')
  assert_same(sources()[1], '# Cell 1\nazz = 1')
end)

-- The user's own mappings for dd/p/P (vim-cutlass, yank-ring plugins, ...)
-- must still run on cell content instead of the built-in commands
h.run_test('user_mappings_for_dd_and_p_apply_in_cell', function()
  local put_calls = 0
  vim.keymap.set('n', 'dd', '"_dd') -- what vim-cutlass maps
  vim.keymap.set('n', 'p', function()
    put_calls = put_calls + 1
    return 'p'
  end, { expr = true })

  local ok, err = pcall(function()
    h.open_notebook('three_cells.ipynb')
    vim.fn.setreg('"', 'KEEP', 'v')
    goto_cell_line(2, 2)
    normal('dd')
    assert_same(sources()[2], '# Cell 2', 'dd should delete the line')
    h.assert_eq(vim.fn.getreg('"'), 'KEEP', 'dd should go through the user mapping (black hole register)')

    goto_cell_line(1, 2)
    normal('p')
    h.assert_eq(put_calls, 1, 'p should go through the user mapping')
    assert_same(sources()[1], '# Cell 1\naKEEP = 1')

    -- Borders still cut the cell
    goto_cell_line(3, 0)
    normal('dd')
    h.assert_eq(#h.get_state().cells, 2, 'dd on a border should still cut the cell')
  end)

  vim.keymap.del('n', 'dd')
  vim.keymap.del('n', 'p')
  if not ok then
    error(err, 0)
  end
end)

local success = h.summary()
vim.cmd(success and 'qa!' or 'cq!')
