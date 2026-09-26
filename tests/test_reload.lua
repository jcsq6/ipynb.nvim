-- Notebook reload tests for ipynb.nvim
-- Run with: nvim --headless -u tests/minimal_init.lua -l tests/test_reload.lua

local h = require('tests.helpers')
local state_mod = require('ipynb.state')

print('')
print(string.rep('=', 60))
print('Running notebook reload tests')
print(string.rep('=', 60))
print('')

local function temp_notebook()
  local path = vim.fn.tempname() .. '.ipynb'
  vim.fn.writefile(vim.fn.readfile(h.fixture_path('simple.ipynb')), path)
  return path
end

--------------------------------------------------------------------------------
-- Test: :w from a cell doesn't make autoread reload the notebook
-- Saving from the edit buffer used to write the file behind the facade's back,
-- so the next :checktime saw a changed file and reloaded it, replacing the
-- notebook state (and dropping its kernel).
--------------------------------------------------------------------------------
h.run_test('write_from_cell_does_not_trigger_reload', function()
  vim.o.autoread = true
  local path = temp_notebook()
  local state = h.open_notebook_path(path)
  local facade_buf = state.facade_buf

  h.enter_cell(1)
  h.set_edit_content('x = 1')
  vim.api.nvim_exec_autocmds('TextChanged', { buffer = h.get_edit_buf() })
  -- Make sure the write lands on a later mtime than the original read
  vim.wait(1100)
  vim.cmd('silent write')
  h.exit_cell()

  vim.cmd('checktime')
  vim.wait(50)

  h.assert_true(state_mod.get_by_facade(facade_buf) == state,
    'Notebook state should survive :checktime after saving from a cell')
  vim.fn.delete(path)
end)

--------------------------------------------------------------------------------
-- Test: :w from a cell writes .ipynb JSON, not the facade text
-- The facade :write issued from the edit buffer's BufWriteCmd didn't run the
-- facade's BufWriteCmd (autocmds don't nest by default), so Neovim wrote the
-- raw facade text over the notebook.
--------------------------------------------------------------------------------
h.run_test('write_from_cell_writes_json', function()
  local path = temp_notebook()
  h.open_notebook_path(path)

  h.enter_cell(1)
  h.set_edit_content('x = 1')
  vim.api.nvim_exec_autocmds('TextChanged', { buffer = h.get_edit_buf() })
  vim.cmd('silent write')
  h.exit_cell()

  local ok, nb = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), '\n'))
  h.assert_true(ok and type(nb) == 'table' and nb.cells, 'Saved file should be notebook JSON')
  h.assert_eq(table.concat(nb.cells[1].source, ''), 'x = 1')
  vim.fn.delete(path)
end)

--------------------------------------------------------------------------------
-- Test: a notebook overwritten with facade text opens with its cells recovered
--------------------------------------------------------------------------------
h.run_test('recovers_facade_text_written_over_notebook', function()
  local path = vim.fn.tempname() .. '.ipynb'
  vim.fn.writefile({
    '# <<ipynb_nvim:code>>', 'a = 1', '# <</ipynb_nvim>>', '',
    '# <<ipynb_nvim:markdown>>', '# Title', '# <</ipynb_nvim>>', '',
  }, path)
  local state = h.open_notebook_path(path)
  h.assert_eq(#state.cells, 2)
  h.assert_eq(state.cells[1].source, 'a = 1')
  h.assert_eq(state.cells[2].type, 'markdown')

  vim.cmd('silent write')
  local ok, nb = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), '\n'))
  h.assert_true(ok and nb.cells and #nb.cells == 2, 'Saving should rewrite it as JSON')
  vim.fn.delete(path)
end)

--------------------------------------------------------------------------------
-- Test: reloading a notebook changed on disk keeps its kernel
--------------------------------------------------------------------------------
h.run_test('reload_keeps_kernel', function()
  local path = temp_notebook()
  local state = h.open_notebook_path(path)
  local facade_buf = state.facade_buf
  local fake_kernel = { job_id = nil, connected = true, pending_cells = {}, cell_index_by_id = {} }
  state.kernel = fake_kernel

  vim.cmd('edit!')
  vim.wait(50)

  local new_state = state_mod.get_by_facade(facade_buf)
  h.assert_true(new_state ~= nil, 'State should exist after reload')
  h.assert_true(new_state.kernel == fake_kernel, 'Kernel should carry over to the reloaded notebook')
  vim.fn.delete(path)
end)

local success = h.summary()
vim.cmd(success and 'qa!' or 'cq!')
