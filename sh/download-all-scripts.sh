#!/bin/sh
# 首次安装入口：把仓库里的脚本、init.d 服务、hotplug 处理器拉到本地。
# 用 wget 而不是 common.sh 的 download_file，因为此时 common.sh 自己也还没就位。

set -e

DIR_SCRIPT=$(dirname "$(readlink -f "$0")")
REPO_RAW_URL="${REPO_RAW_URL:-https://raw.githubusercontent.com/AfxMsgBox/MyRule/main}"

# 普通下载：失败时给一次直连重试（首次安装时本地代理通常还没起来）
_fetch() {
    _url="$1"; _dst="$2"
    mkdir -p "$(dirname "$_dst")"
    if wget -q -O "$_dst" "$_url"; then return 0; fi
    echo "下载失败，重试：$_url" >&2
    wget -O "$_dst" "$_url"
}

# 仓库里的可执行 / 配置脚本，全部下到 $DIR_SCRIPT
for name in \
        env.conf \
        common.sh \
        keeplive.sh \
        update-agh-config.sh \
        update-all-configs.sh \
        update-all-configs-restart-services.sh \
        update-core-config.sh \
        update-proxy-rule.sh \
        download-all-scripts.sh \
        inst.sh; do
    _fetch "$REPO_RAW_URL/sh/$name" "$DIR_SCRIPT/$name"
done

# OpenWrt 服务与热插拔处理器，下到系统目录
_fetch "$REPO_RAW_URL/sh/etc/init.d/proxy_core"            /etc/init.d/proxy_core
_fetch "$REPO_RAW_URL/sh/etc/init.d/agh"                   /etc/init.d/agh
_fetch "$REPO_RAW_URL/sh/etc/hotplug.d/net/99-meta-route"  /etc/hotplug.d/net/99-meta-route

chmod +x /etc/init.d/proxy_core /etc/init.d/agh
chmod +x "$DIR_SCRIPT"/*.sh

echo "下载完成。下一步：编辑 $DIR_SCRIPT/env.conf（可选）与 \$CORE_DIR/local.conf 后运行 update-all-configs.sh。"
