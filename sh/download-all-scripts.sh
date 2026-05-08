#!/bin/sh
# 首次安装入口：把仓库脚本、init.d / systemd 服务、hotplug 处理器拉到本地。
# 自动识别 OpenWrt（procd + hotplug）与 Debian/Ubuntu（systemd），分发对应的服务文件。
# 用 wget 而不是 common.sh 的 download_file，因为此时 common.sh 自己也还没就位。

set -e

DIR_SCRIPT=$(dirname "$(readlink -f "$0")")
REPO_RAW_URL="${REPO_RAW_URL:-https://raw.githubusercontent.com/AfxMsgBox/MyRule/main}"

# ----------------------------------------------------------------------
# OS 识别：openwrt | systemd | unknown
# ----------------------------------------------------------------------
detect_os() {
    if [ -f /etc/openwrt_release ] || grep -qs '^ID=.*openwrt' /etc/os-release; then
        echo openwrt
        return
    fi
    if command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ]; then
        echo systemd
        return
    fi
    echo unknown
}

OS_TYPE="${OS_TYPE:-$(detect_os)}"
echo "目标系统：$OS_TYPE"

_fetch() {
    _url="$1"; _dst="$2"
    mkdir -p "$(dirname "$_dst")"
    if wget -q -O "$_dst" "$_url"; then return 0; fi
    echo "下载失败，重试：$_url" >&2
    wget -O "$_dst" "$_url"
}

# ----------------------------------------------------------------------
# 1. 公共脚本（两个平台都装）
# ----------------------------------------------------------------------
for name in \
        env.conf \
        common.sh \
        keeplive.sh \
        setup-fake-ip-route.sh \
        update-agh-config.sh \
        update-all-configs.sh \
        update-all-configs-restart-services.sh \
        update-core-config.sh \
        update-proxy-rule.sh \
        download-all-scripts.sh \
        inst.sh; do
    _fetch "$REPO_RAW_URL/sh/$name" "$DIR_SCRIPT/$name"
done
chmod +x "$DIR_SCRIPT"/*.sh

# ----------------------------------------------------------------------
# 2. 服务文件（按平台分发）
# ----------------------------------------------------------------------
case "$OS_TYPE" in
    openwrt)
        _fetch "$REPO_RAW_URL/sh/etc/init.d/proxy_core"           /etc/init.d/proxy_core
        _fetch "$REPO_RAW_URL/sh/etc/init.d/agh"                  /etc/init.d/agh
        _fetch "$REPO_RAW_URL/sh/etc/hotplug.d/net/99-meta-route" /etc/hotplug.d/net/99-meta-route
        chmod +x /etc/init.d/proxy_core /etc/init.d/agh /etc/hotplug.d/net/99-meta-route
        echo "已安装到 /etc/init.d/{proxy_core,agh}、/etc/hotplug.d/net/99-meta-route"
        echo "启用与启动："
        echo "  service proxy_core enable && service proxy_core start"
        echo "  service agh enable && service agh start"
        ;;
    systemd)
        _fetch "$REPO_RAW_URL/sh/etc/systemd/system/proxy_core.service" /etc/systemd/system/proxy_core.service
        _fetch "$REPO_RAW_URL/sh/etc/systemd/system/agh.service"        /etc/systemd/system/agh.service
        systemctl daemon-reload
        echo "已安装到 /etc/systemd/system/{proxy_core,agh}.service"
        echo "启用与启动："
        echo "  systemctl enable --now proxy_core.service"
        echo "  systemctl enable --now agh.service"
        echo "（路由修正由 proxy_core.service 的 ExecStartPost 调用 setup-fake-ip-route.sh）"
        ;;
    *)
        echo "未识别的系统，跳过服务文件安装。" >&2
        echo "可设置 OS_TYPE=openwrt 或 OS_TYPE=systemd 后重跑：" >&2
        echo "  OS_TYPE=systemd sh $DIR_SCRIPT/download-all-scripts.sh" >&2
        ;;
esac

echo
echo "下载完成。下一步："
echo "  1. 编辑 $DIR_SCRIPT/env.local.conf（可选，覆盖默认端口/路径）"
echo "  2. 编辑 \${CORE_DIR:-/etc/proxy/core}/local.conf 写入订阅 URL 等敏感参数"
echo "  3. 运行 sh $DIR_SCRIPT/update-all-configs.sh"
