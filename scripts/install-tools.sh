#!/usr/bin/env bash
# プラグイン(Lua)の検査に使うツールを入れる。
#
#   scripts/install-tools.sh [prefix]   (prefix の既定は /usr/local)
#
# 入れるのは Neovim、stylua、lua-language-server。開発用の devcontainer と CI の両方から
# 呼ぶので、手元と CI で同じ版になる。書き込めない prefix には sudo で実行する。
set -euo pipefail

STYLUA_VERSION=2.6.0
STYLUA_SHA256_X86_64=a485f72bbfa22e4642e77a84b5edc2611a5cab7477b34e2e709dd8f78e919895
STYLUA_SHA256_AARCH64=8e67539e5fdf7a81cd03cf592b0df18d3bb96ee17a5ea5d9bf67b86387b903b0
LUALS_VERSION=3.19.2
LUALS_SHA256_X86_64=93ad326b10f6c00911dd8c450fa098332dbd8f9f45d1052f5636a2d54479b947
LUALS_SHA256_AARCH64=17b8e401a874440adeb649e5024c364f2bb9d15156c74a40e56d1ae9a1b2e4f2

prefix=${1:-/usr/local}
root=$(cd "$(dirname "$0")/.." && pwd)

# Neovim は汎用イメージと同じ版にするため、バージョンとチェックサムを Dockerfile から読む。
dockerfile_arg() {
  sed -n "s/^ARG $1=//p" "$root/image/Dockerfile"
}
nvim_version=$(dockerfile_arg NVIM_VERSION)

case "$(uname -m)" in
  x86_64)
    nvim_arch=x86_64 nvim_sha=$(dockerfile_arg NVIM_SHA256_X86_64)
    stylua_arch=x86_64 stylua_sha=$STYLUA_SHA256_X86_64
    luals_arch=x64 luals_sha=$LUALS_SHA256_X86_64
    ;;
  aarch64 | arm64)
    nvim_arch=arm64 nvim_sha=$(dockerfile_arg NVIM_SHA256_ARM64)
    stylua_arch=aarch64 stylua_sha=$STYLUA_SHA256_AARCH64
    luals_arch=arm64 luals_sha=$LUALS_SHA256_AARCH64
    ;;
  *)
    echo "対応していないアーキテクチャです: $(uname -m)" >&2
    exit 1
    ;;
esac

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# download <URL> <SHA-256> <保存先>
download() {
  curl -fsSL -o "$3" "$1"
  echo "$2  $3" | sha256sum -c - >/dev/null
}

# 本体は lib の下に置き、bin からはリンクや小さなスクリプトで呼ぶ。Neovim と
# lua-language-server は、実行ファイルの隣のファイル(ランタイムなど)を必要とするため。
lib=$prefix/lib/nvim-dc-tools
rm -rf "$lib"
mkdir -p "$lib/nvim" "$lib/luals" "$prefix/bin"

download "https://github.com/neovim/neovim/releases/download/v${nvim_version}/nvim-linux-${nvim_arch}.tar.gz" \
  "$nvim_sha" "$tmp/nvim.tar.gz"
tar -xzf "$tmp/nvim.tar.gz" -C "$lib/nvim" --strip-components=1
ln -sf "$lib/nvim/bin/nvim" "$prefix/bin/nvim"

download "https://github.com/JohnnyMorganz/StyLua/releases/download/v${STYLUA_VERSION}/stylua-linux-${stylua_arch}.zip" \
  "$stylua_sha" "$tmp/stylua.zip"
unzip -q "$tmp/stylua.zip" -d "$lib"
chmod +x "$lib/stylua"
ln -sf "$lib/stylua" "$prefix/bin/stylua"

download "https://github.com/LuaLS/lua-language-server/releases/download/${LUALS_VERSION}/lua-language-server-${LUALS_VERSION}-linux-${luals_arch}.tar.gz" \
  "$luals_sha" "$tmp/luals.tar.gz"
tar -xzf "$tmp/luals.tar.gz" -C "$lib/luals"
printf '#!/bin/sh\nexec "%s/luals/bin/lua-language-server" "$@"\n' "$lib" >"$prefix/bin/lua-language-server"
chmod +x "$prefix/bin/lua-language-server"

"$prefix/bin/nvim" --version | head -n1
echo "stylua $("$prefix/bin/stylua" --version | cut -d' ' -f2)"
echo "lua-language-server $("$prefix/bin/lua-language-server" --version)"
