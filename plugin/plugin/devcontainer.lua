-- devcontainer を作成して接続するコマンドを定義する。
--
-- 汎用イメージでは、エントリポイントがこのファイルを `--cmd` で読み込む。
-- ユーザー設定のプラグインマネージャ(lazy.nvim など)が runtimepath を
-- リセットしても使えるように、lua/ の場所を package.path にも足しておく。
if vim.g.loaded_devcontainer then
  return
end
vim.g.loaded_devcontainer = true

local root = vim.fs.dirname(vim.fs.dirname(vim.fs.abspath(debug.getinfo(1, 'S').source:sub(2))))
package.path = ('%s/lua/?.lua;%s/lua/?/init.lua;'):format(root, root) .. package.path

vim.api.nvim_create_user_command('DevcontainerUp', function()
  require('devcontainer').up()
end, { desc = 'devcontainer.json から devcontainer を作成する' })

vim.api.nvim_create_user_command('DevcontainerConnect', function()
  require('devcontainer').connect()
end, { desc = 'UI を devcontainer の中の nvim サーバに繋ぎ替える' })

-- 起動時にワークスペースに devcontainer.json があれば、接続できることを知らせる。
vim.api.nvim_create_autocmd('VimEnter', {
  once = true,
  callback = function()
    local env = require('devcontainer.env')
    if env.is_ui_side() and env.find_config(env.workspace()) then
      vim.notify(
        'devcontainer.json があります。:DevcontainerConnect で devcontainer に接続できます',
        vim.log.levels.INFO
      )
    end
  end,
})
