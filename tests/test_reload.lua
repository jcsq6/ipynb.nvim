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

---Rewrite the notebook on disk behind the editor's back
---@param path string
---@param source string New source of the first cell
local function change_on_disk(path, source)
  local nb = vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
  nb.cells[1].source = { source }
  vim.fn.writefile({ vim.json.encode(nb) }, path)
end

---@param path string
---@return string
local function first_cell_on_disk(path)
  local nb = vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
  return table.concat(nb.cells[1].source, '')
end

---Collect notifications at or above WARN while fn runs
---@param fn function
---@return string[]
local function capture_warnings(fn)
  local warnings = {}
  local orig = vim.notify
  vim.notify = function(msg, level)
    if (level or 0) >= vim.log.levels.WARN then
      table.insert(warnings, msg)
    end
  end
  local ok, err = pcall(fn)
  vim.notify = orig
  assert(ok, err)
  return warnings
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

--------------------------------------------------------------------------------
-- Test: a cell edited before a reload still syncs and leaves afterwards
-- The reload reuses the cell's hidden edit buffer, whose sync autocmds and
-- keymaps were bound once to the notebook state from before the reload: edits
-- never reached the notebook and <Esc> couldn't leave the cell.
--------------------------------------------------------------------------------
h.run_test('reload_rebinds_reused_cell_buffer', function()
  local path = temp_notebook()
  h.open_notebook_path(path)
  -- Persist the generated cell IDs so the reload finds the same cells
  vim.cmd('silent write')
  h.enter_cell(1)
  local edit_buf = h.get_edit_buf()
  h.exit_cell()

  vim.cmd('edit!')
  vim.wait(50)

  local state = h.get_state()
  h.enter_cell(1)
  h.assert_eq(h.get_edit_buf(), edit_buf, 'Reload should reuse the cell edit buffer')
  h.set_edit_content('y = 2')
  vim.api.nvim_exec_autocmds('TextChanged', { buffer = edit_buf })
  h.assert_eq(state.cells[1].source, 'y = 2')

  h.feedkeys('<Esc>')
  h.assert_true(state.edit_state == nil, '<Esc> should leave the cell')
  vim.fn.delete(path)
end)

--------------------------------------------------------------------------------
-- Test: :w doesn't overwrite a notebook changed on disk; :w! does
-- The facade is an acwrite buffer, so Neovim's own "changed since reading"
-- check never ran and :w silently replaced changes made by other programs.
--------------------------------------------------------------------------------
h.run_test('write_refuses_notebook_changed_on_disk', function()
  local path = temp_notebook()
  local state = h.open_notebook_path(path)

  h.enter_cell(1)
  h.set_edit_content('mine = 1')
  vim.api.nvim_exec_autocmds('TextChanged', { buffer = h.get_edit_buf() })
  h.exit_cell()
  change_on_disk(path, 'theirs = 1')

  local warnings = capture_warnings(function()
    pcall(vim.cmd, 'silent write')
  end)
  h.assert_eq(first_cell_on_disk(path), 'theirs = 1', ':w should keep the change on disk')
  h.assert_true(vim.bo[state.facade_buf].modified, 'Notebook should stay modified')
  h.assert_true(#warnings > 0, ':w should say why it refused')

  vim.cmd('silent write!')
  h.assert_eq(first_cell_on_disk(path), 'mine = 1', ':w! should overwrite')
  h.assert_true(not vim.bo[state.facade_buf].modified, 'Notebook should be saved')
  vim.fn.delete(path)
end)

--------------------------------------------------------------------------------
-- Test: an unchanged notebook reloads when the file changes on disk
-- Neovim's 'autoread' check skips acwrite buffers.
--------------------------------------------------------------------------------
h.run_test('unmodified_notebook_reloads_when_changed_on_disk', function()
  local path = temp_notebook()
  local state = h.open_notebook_path(path)
  local facade_buf = state.facade_buf

  change_on_disk(path, 'theirs = 1')
  vim.api.nvim_exec_autocmds('FocusGained', {})
  vim.wait(200, function()
    local s = state_mod.get_by_facade(facade_buf)
    return s ~= nil and s.cells[1].source == 'theirs = 1'
  end)

  h.assert_eq(state_mod.get_by_facade(facade_buf).cells[1].source, 'theirs = 1')
  vim.fn.delete(path)
end)

--------------------------------------------------------------------------------
-- Test: a notebook with unsaved changes warns instead of reloading
--------------------------------------------------------------------------------
h.run_test('modified_notebook_warns_when_changed_on_disk', function()
  local path = temp_notebook()
  local state = h.open_notebook_path(path)

  h.enter_cell(1)
  h.set_edit_content('mine = 1')
  vim.api.nvim_exec_autocmds('TextChanged', { buffer = h.get_edit_buf() })
  h.exit_cell()
  change_on_disk(path, 'theirs = 1')

  local warnings = capture_warnings(function()
    vim.api.nvim_exec_autocmds('FocusGained', {})
    vim.wait(100)
  end)
  h.assert_eq(state.cells[1].source, 'mine = 1', 'Unsaved changes should be kept')
  h.assert_eq(#warnings, 1, 'Should warn once')

  -- The same change on disk doesn't warn again
  warnings = capture_warnings(function()
    vim.api.nvim_exec_autocmds('FocusGained', {})
    vim.wait(100)
  end)
  h.assert_eq(#warnings, 0, 'Should not warn twice for the same change')
  vim.bo[state.facade_buf].modified = false
  vim.fn.delete(path)
end)

local success = h.summary()
vim.cmd(success and 'qa!' or 'cq!')
