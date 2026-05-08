#!/bin/sh
# 修复 mihomo 启动 TUN 后路由子网掩码总是 /30 的 bug：
# 不论 config.yaml 里 fake-ip-range 写多少，mihomo 都会把路由加成
# <网段起始>/30，导致只覆盖 4 个 IP。这里先删错的、再加正确的网段。
#
# 同时被两类触发器调用：
#   - OpenWrt 的 hotplug：/etc/hotplug.d/net/99-meta-route
#   - Debian/Ubuntu 的 systemd：proxy_core.service 的 ExecStartPost

DIR_SCRIPT=$(dirname "$(readlink -f "$0")")
# shellcheck disable=SC1091
[ -f "$DIR_SCRIPT/env.conf" ] && . "$DIR_SCRIPT/env.conf"
FAKE_IP_CIDR="${FAKE_IP_CIDR:-172.16.0.0/12}"
TUN_IFACES="${TUN_IFACES:-utun Meta}"
LOG_TAG="${LOG_TAG:-MyProxy}"

# 网段起始 IP，用来匹配 mihomo 加错的 /30 路由
_BASE_IP="${FAKE_IP_CIDR%/*}"

# 找到当前真正存在的 TUN 接口；hotplug 直接用 $INTERFACE 命中，
# systemd ExecStartPost 启动时 TUN 可能还没就绪，等最多 10 秒
_find_iface() {
    if [ -n "$INTERFACE" ]; then
        for _i in $TUN_IFACES; do
            [ "$INTERFACE" = "$_i" ] && { echo "$INTERFACE"; return 0; }
        done
    fi
    _try=0
    while [ "$_try" -lt 10 ]; do
        for _i in $TUN_IFACES; do
            if ip link show "$_i" >/dev/null 2>&1; then
                echo "$_i"
                return 0
            fi
        done
        sleep 1
        _try=$((_try + 1))
    done
    return 1
}

# OpenWrt hotplug 会传 ACTION=add，systemd 不传；只在非 add 的 hotplug 场景退出
case "$ACTION" in
    add|"") ;;
    *) exit 0 ;;
esac

target=$(_find_iface) || {
    logger -t "$LOG_TAG" "TUN 接口 ($TUN_IFACES) 未上线，跳过路由配置"
    exit 0
}

# 先删 mihomo 加错的 /30 路由（错时存在、不存在时静默）
ip route del "$_BASE_IP/30" 2>/dev/null

# 加上配置中真正期望的 fake-ip 网段；replace 等同于"存在则替换、不存在则新增"
ip route replace "$FAKE_IP_CIDR" dev "$target"

logger -t "$LOG_TAG" "fake-ip 路由 $FAKE_IP_CIDR -> $target"
