-- 汎用コンテナと devcontainer の間で決めておく名前とパス。
--
-- ソケット用の volume 名とマウント先は、ランチャー(launcher/src/run.rs の SOCKET_VOLUME)と
-- イメージ(image/Dockerfile)でも同じものを使っている。
local M = {}

--- UI 側と devcontainer 側の nvim が通信する Unix ソケットを置く named volume。
M.socket_volume = 'nvim-dc-sockets'
--- ソケット用の volume のマウント先。汎用コンテナと devcontainer で同じパスにする。
M.socket_dir = '/run/nvim-dc'
--- devcontainer の中で、汎用イメージの Neovim 本体(/opt/nvim)をマウントする場所。
M.runtime_dir = '/opt/nvim-dc-runtime'

--- ランチャーから起動された汎用コンテナの中かどうか。
function M.is_ui_side()
  return vim.env.NVIM_DC_IMAGE ~= nil and vim.env.NVIM_DC_IMAGE ~= ''
end

--- ワークスペースのパス(ホストと同じ絶対パス)。
function M.workspace()
  local ws = vim.env.NVIM_DC_WORKSPACE
  if ws and ws ~= '' then
    return ws
  end
  return vim.fn.getcwd()
end

--- 汎用イメージの参照。devcontainer に Neovim 本体を渡すときに使う。
function M.image()
  return M.is_ui_side() and vim.env.NVIM_DC_IMAGE or nil
end

--- ワークスペースの devcontainer.json。devcontainer CLI の既定と同じ順に探す。
function M.find_config(workspace)
  for _, rel in ipairs({ '.devcontainer/devcontainer.json', '.devcontainer.json' }) do
    local path = vim.fs.joinpath(workspace, rel)
    if vim.uv.fs_stat(path) then
      return path
    end
  end
  return nil
end

--- Neovim 本体を入れる named volume の名前。バージョンごとに分ける。
---
--- UI 側とサーバ側のバージョンを一致させるため、名前にこの nvim のバージョンを含める。
--- 開発版のビルドは同じバージョン番号でも中身が変わるので、ビルドの識別子も含める。
function M.runtime_volume()
  local v = vim.version()
  local version = ('%d.%d.%d'):format(v.major, v.minor, v.patch)
  if v.prerelease then
    version = version .. '-' .. tostring(v.build or v.prerelease)
  end
  return 'nvim-dc-nvim-' .. version:gsub('[^%w_.-]', '-')
end

--- コンテナ ID の短縮形(docker の表示と同じ先頭12桁)。
function M.short_id(container_id)
  return container_id:sub(1, 12)
end

--- devcontainer ごとのソケットのパス。
function M.socket_path(container_id)
  return ('%s/%s.sock'):format(M.socket_dir, M.short_id(container_id))
end

--- devcontainer ごとのサーバのログのパス。
function M.server_log_path(container_id)
  return ('%s/%s.log'):format(M.socket_dir, M.short_id(container_id))
end

return M
