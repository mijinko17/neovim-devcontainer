#!/bin/sh
# 汎用コンテナのエントリポイント。
#
# ランチャーはホストの UID/GID で起動するので、その UID がイメージの passwd にない。
# getpwuid が失敗するとツールが壊れるので、起動のたびに登録してから nvim を起動する。
set -eu

uid=$(id -u)
gid=$(id -g)

if ! getent group "$gid" >/dev/null; then
  echo "nvim-dc:x:${gid}:" >>/etc/group
fi
if ! getent passwd "$uid" >/dev/null; then
  echo "nvim-dc:x:${uid}:${gid}:nvim-dc:${HOME}:/bin/bash" >>/etc/passwd
fi

# ホストから引き継いだ TERM の端末定義がイメージにないとき(xterm-ghostty など)は、
# 汎用の xterm-256color に落とす。定義のない TERM だと、nvim から起動するコマンドが
# 「unknown terminal type」で失敗するため。
if [ -n "${TERM:-}" ] && ! infocmp "$TERM" >/dev/null 2>&1; then
  export TERM=xterm-256color
fi

# 本プラグインは runtimepath ではなく --cmd で読み込む。ユーザー設定のプラグインマネージャ
# (lazy.nvim など)が runtimepath をリセットしても、コマンドが消えないようにするため。
exec nvim --cmd 'source /opt/nvim-dc/plugin/devcontainer.lua' "$@"
