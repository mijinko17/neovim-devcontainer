-- テストで使う比較の道具。
local M = {}

--- 2つの値が(テーブルなら中身まで)等しいことを確かめる。
function M.eq(expected, actual)
  if not vim.deep_equal(expected, actual) then
    error(('期待した値:\n%s\n実際の値:\n%s'):format(vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

--- fn が async.fail() で失敗し、そのメッセージが pattern を(そのままの文字列として)含むことを確かめる。
function M.fails(pattern, fn)
  local ok, err = pcall(fn)
  if ok then
    error('失敗するはずの処理が成功した', 2)
  end
  local message = type(err) == 'table' and err.message or nil
  if not message then
    error('async.fail() 以外のエラー: ' .. tostring(err), 2)
  end
  if not message:find(pattern, 1, true) then
    error(('メッセージ %q が %q を含まない'):format(message, pattern), 2)
  end
end

return M
