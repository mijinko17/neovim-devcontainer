-- プラグインのテストを実行する。テスト用のプラグインには頼らない。
--
--   nvim --headless -l tests/run.lua
--
-- `tests/*_spec.lua` は「テスト名 → 関数」のテーブルを返す。関数がエラーにならなければ成功。
-- 対象は、入力と出力だけで決まる処理に絞っている。Docker や devcontainer CLI を呼ぶ流れは
-- 手で確かめる(docs/development.md の「動作確認」)。
local tests_dir = vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
local root = vim.fs.dirname(tests_dir)
package.path = ('%s/lua/?.lua;%s/lua/?/init.lua;%s/?.lua;%s'):format(root, root, tests_dir, package.path)

local specs = vim.fn.glob(tests_dir .. '/*_spec.lua', false, true)
table.sort(specs)

local passed, failed = 0, 0
for _, path in ipairs(specs) do
  local spec = vim.fs.basename(path)
  local cases = dofile(path)
  local names = vim.tbl_keys(cases)
  table.sort(names)
  for _, name in ipairs(names) do
    local ok, err = xpcall(cases[name], debug.traceback)
    if ok then
      passed = passed + 1
    else
      failed = failed + 1
      io.stdout:write(('FAIL %s: %s\n%s\n\n'):format(spec, name, err))
    end
  end
end

io.stdout:write(('%d passed, %d failed\n'):format(passed, failed))
if failed > 0 or passed == 0 then
  os.exit(1)
end
