#!/usr/bin/env bash
set -euo pipefail

# ランチャーを musl で静的リンクするためのツールチェーン。
# ターゲットはこのコンテナのアーキテクチャに合わせる(x86_64 / aarch64)。
sudo apt-get update
sudo apt-get install -y --no-install-recommends musl-tools
rustup target add "$(uname -m)-unknown-linux-musl"

# プラグインから呼ぶ devcontainer CLI
npm install -g @devcontainers/cli

# Claude Code の状態(アカウント情報など)をホストからコピーする。認証情報は ~/.claude のマウントで共有済み。
if [ ! -f "$HOME/.claude.json" ] && [ -f /mnt/host-claude.json ]; then
  cp /mnt/host-claude.json "$HOME/.claude.json"
fi
