-- 汎用コンテナの Neovim の既定設定。ホストの設定はマウントしないので、常にこれを使う。
-- 最低限の使い勝手だけを整え、プラグインは入れない。
--
-- clipboard は設定しない。イメージにはクリップボードのツールがないので、
-- "+ レジスタは端末が対応していれば Neovim 標準の OSC 52 で扱われる。
vim.opt.number = true
vim.opt.expandtab = true
vim.opt.shiftwidth = 2
vim.opt.tabstop = 2
vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.termguicolors = true
