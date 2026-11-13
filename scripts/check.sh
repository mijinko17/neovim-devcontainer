#!/usr/bin/env bash
# 整形・静的解析・テストを確かめる。CI(.github/workflows/ci.yml)も同じものを実行する。
#
#   scripts/check.sh            すべて
#   scripts/check.sh launcher   ランチャー(Rust)だけ
#   scripts/check.sh plugin     プラグイン(Lua)だけ
#
# 途中で失敗しても残りを実行し、最後にまとめて結果を出す。1つでも失敗すれば終了コードは 1。
# プラグインの検査に使うツールは scripts/install-tools.sh で入れる。
set -uo pipefail

cd "$(dirname "$0")/.."

failed=()

# run <名前> <コマンド>...
run() {
  local name=$1
  shift
  echo "==> $name"
  if ! "$@"; then
    failed+=("$name")
  fi
  echo
}

check_launcher() {
  run 'ランチャー: 整形' cargo fmt --manifest-path launcher/Cargo.toml --check
  run 'ランチャー: lint' cargo clippy --manifest-path launcher/Cargo.toml --locked --all-targets -- -D warnings
  run 'ランチャー: テスト' cargo test --manifest-path launcher/Cargo.toml --locked
}

# 静的解析は vim.* の型定義を Neovim のランタイムから読む(.luarc.json の workspace.library)。
analyze_plugin() {
  local runtime log status
  runtime=$(nvim --clean --headless '+lua io.write(vim.env.VIMRUNTIME)' +q) || return 1
  log=$(mktemp -d)
  VIMRUNTIME=$runtime lua-language-server --check . --checklevel=Warning --logpath "$log" --metapath "$log/meta"
  status=$?
  rm -rf "$log"
  return "$status"
}

check_plugin() {
  local tool
  for tool in nvim stylua lua-language-server; do
    if ! command -v "$tool" >/dev/null; then
      echo "$tool がありません。scripts/install-tools.sh で入れてください。" >&2
      failed+=('プラグイン: ツールがない')
      return
    fi
  done
  run 'プラグイン: 整形' stylua --check plugin image/config
  run 'プラグイン: 静的解析' analyze_plugin
  run 'プラグイン: テスト' nvim --headless -l plugin/tests/run.lua
}

if [ $# -eq 0 ]; then
  set -- launcher plugin
fi
for target in "$@"; do
  case "$target" in
    launcher) check_launcher ;;
    plugin) check_plugin ;;
    *)
      echo "不明な対象: $target(launcher か plugin)" >&2
      exit 2
      ;;
  esac
done

if [ ${#failed[@]} -gt 0 ]; then
  echo '失敗:'
  printf '  %s\n' "${failed[@]}"
  exit 1
fi
echo 'すべて通りました'
