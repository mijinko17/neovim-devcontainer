-- devcontainer CLI の出力を表示するバッファ。
--
-- 初回の `devcontainer up` はイメージのビルドで数分かかるので、進み具合を見せる。
local api = vim.api

local M = {}

local NAME = 'devcontainer://log'
local HEIGHT = 12

local bufnr

local function buf()
  if bufnr and api.nvim_buf_is_valid(bufnr) then
    return bufnr
  end
  bufnr = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(bufnr, NAME)
  vim.bo[bufnr].bufhidden = 'hide'
  vim.bo[bufnr].swapfile = false
  return bufnr
end

local function windows()
  if not (bufnr and api.nvim_buf_is_valid(bufnr)) then
    return {}
  end
  return vim.fn.win_findbuf(bufnr)
end

--- ログを空にする。
function M.clear()
  api.nvim_buf_set_lines(buf(), 0, -1, false, {})
end

--- 行を追加し、ログを表示しているウィンドウを末尾までスクロールする。
function M.append(lines)
  local b = buf()
  local empty = api.nvim_buf_line_count(b) == 1 and api.nvim_buf_get_lines(b, 0, 1, false)[1] == ''
  api.nvim_buf_set_lines(b, empty and 0 or -1, -1, false, lines)
  local last = api.nvim_buf_line_count(b)
  for _, win in ipairs(windows()) do
    api.nvim_win_set_cursor(win, { last, 0 })
  end
end

--- 画面の下にログを開く。カーソルは元のウィンドウに残す。
function M.open()
  if #windows() > 0 then
    return
  end
  local cur = api.nvim_get_current_win()
  vim.cmd(('botright %dsplit'):format(HEIGHT))
  api.nvim_win_set_buf(0, buf())
  api.nvim_set_option_value('number', false, { scope = 'local' })
  api.nvim_set_option_value('wrap', false, { scope = 'local' })
  api.nvim_win_set_cursor(0, { api.nvim_buf_line_count(buf()), 0 })
  api.nvim_set_current_win(cur)
end

--- ログを表示しているウィンドウを閉じる。最後のウィンドウは閉じない。
function M.close()
  for _, win in ipairs(windows()) do
    if #api.nvim_list_wins() > 1 then
      api.nvim_win_close(win, false)
    end
  end
end

--- vim.system の stdout / stderr に渡すコールバックを作る。
---
--- 出力は行の途中で区切られて届くので、改行までためてから追加する。
--- エスケープシーケンス(色付けなど)は取り除く。
function M.writer()
  local pending = ''
  return function(_, data)
    if not data then
      if pending ~= '' then
        local rest = pending
        pending = ''
        vim.schedule(function()
          M.append({ rest })
        end)
      end
      return
    end
    -- エスケープシーケンスがチャンクの境目で切れても取り除けるように、前の残りとつないでから処理する。
    local text = (pending .. data):gsub('\27%[[%d;?]*[%a]', ''):gsub('\r', '')
    local lines = vim.split(text, '\n', { plain = true })
    pending = table.remove(lines)
    if #lines > 0 then
      vim.schedule(function()
        M.append(lines)
      end)
    end
  end
end

return M
