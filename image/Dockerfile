# 汎用 Neovim イメージ
#
# UI 側の Neovim が動く場所。devcontainer の作成と管理もここから行う。
# 実行ユーザーはランチャーがホストの UID/GID で指定するので、どの UID でも動くように作る。

ARG DOCKER_VERSION=29
ARG NODE_VERSION=22

# docker CLI と compose / buildx プラグインは静的リンクなので、公式イメージから取り出す。
FROM docker:${DOCKER_VERSION}-cli AS docker-cli

# Neovim の公式ビルドは glibc 前提なので、Debian ベースにする。
FROM node:${NODE_VERSION}-bookworm-slim

ARG TARGETARCH
ARG NVIM_VERSION=0.12.6
ARG NVIM_SHA256_X86_64=474430d53e6264f6d6dd18db42d6dc9df3a1b56ca9e88a325bbf860e1a811d87
ARG NVIM_SHA256_ARM64=8f1f64a0bdb97247034038c3823c6cbad5bdf9ecd5751b85494b71c3ee04c815
ARG DEVCONTAINER_CLI_VERSION=0.90.0

# ncurses-term は、ホストから引き継ぐ TERM(xterm-kitty など)の端末定義のため。
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
         ca-certificates curl git openssh-client ncurses-term \
    && rm -rf /var/lib/apt/lists/*

# ベースイメージの node ユーザー(UID 1000)を消す。ホストの UID がこれと重なると、
# passwd 上の HOME が /home/node になり、ssh などが $HOME ではなくそちらを見るため。
RUN userdel --remove node \
    && ! getent passwd 1000 \
    && ! getent group 1000

COPY --from=docker-cli /usr/local/bin/docker /usr/local/bin/docker
COPY --from=docker-cli /usr/local/libexec/docker/cli-plugins /usr/local/libexec/docker/cli-plugins

# Neovim は /opt/nvim に置く。後のステップで、このディレクトリを devcontainer 側にも渡す。
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) arch=x86_64; sha="${NVIM_SHA256_X86_64}" ;; \
      arm64) arch=arm64;  sha="${NVIM_SHA256_ARM64}" ;; \
      *) echo "unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/nvim.tar.gz \
      "https://github.com/neovim/neovim/releases/download/v${NVIM_VERSION}/nvim-linux-${arch}.tar.gz"; \
    echo "${sha}  /tmp/nvim.tar.gz" | sha256sum -c -; \
    mkdir -p /opt/nvim; \
    tar -xzf /tmp/nvim.tar.gz -C /opt/nvim --strip-components=1; \
    rm /tmp/nvim.tar.gz; \
    ln -s /opt/nvim/bin/nvim /usr/local/bin/nvim; \
    nvim --version | head -1

RUN npm install -g "@devcontainers/cli@${DEVCONTAINER_CLI_VERSION}" \
    && npm cache clean --force

# ホストに ~/.config/nvim がないときに使う既定設定。
# ユーザー設定が見つからないと、Neovim は $XDG_CONFIG_DIRS/nvim/init.lua を読む。
COPY config/init.lua /etc/xdg/nvim/init.lua

# どの UID で動いても書き込めるように、HOME と永続化先を 1777 で用意する。
# named volume は初回マウント時にイメージ側のパーミッションを引き継ぐ。
ENV HOME=/home/nvim-dc \
    LANG=C.UTF-8
RUN set -eux; \
    for d in "$HOME" "$HOME/.config" "$HOME/.local" "$HOME/.local/share" "$HOME/.local/state" \
             "$HOME/.local/share/nvim" "$HOME/.local/state/nvim" "$HOME/.cache" "$HOME/.cache/nvim"; do \
      mkdir -p "$d"; chmod 1777 "$d"; \
    done

# 実行時の UID/GID を passwd / group に登録できるように、書き込み可能にしておく。
# 登録がないと、Node の os.userInfo() や ssh など getpwuid を使うものが失敗する。
# Docker ソケットをマウントする時点でホストの root 相当なので、権限の緩さは問題にしない。
RUN chmod 666 /etc/passwd /etc/group
COPY entrypoint.sh /usr/local/bin/nvim-dc-entrypoint

WORKDIR /home/nvim-dc
ENTRYPOINT ["nvim-dc-entrypoint"]
