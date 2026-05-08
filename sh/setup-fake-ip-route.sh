#!/bin/sh
# 修复 mihomo 启动 TUN 后路由子网掩码总是 /30 的 bug：
# 不论 config.yaml 里 fake-ip-range 写多少，mihomo 都会把路由加成
# <网段起始>/30，只覆盖 4 个 IP。本脚本：
#   1. 等 TUN 接口出现
#   2. 等 mihomo 把那条 /30 错路由真正加上来（关键：早于此时 del 是 no-op，
#      然后 mihomo 才覆盖回 /30，问题没解）
#   3. del 错路由 + replace 成正确网段
#   4. 二次校验：如果 mihomo 又抢回去，再修一次
#
# 触发器：
#   - OpenWrt 的 hotplug：/etc/hotplug.d/net/99-meta-route（接口 add 时触发，
#     /30 通常此时已存在）
#   - Debian/Ubuntu 的 systemd：proxy_core.service 的 ExecStartPost（mihomo 进程
#     刚 fork，TUN 与 /30 都还没就绪，需等待）

DIR_SCRIPT=$(dirname "$(readlink -f "$0")")
# shellcheck disable=SC1091
[ -f "$DIR_SCRIPT/env.conf" ] && . "$DIR_SCRIPT/env.conf"
FAKE_IP_CIDR="${FAKE_IP_CIDR:-172.16.0.0/12}"
TUN_IFACES="${TUN_IFACES:-utun Meta}"
LOG_TAG="${LOG_TAG:-MyProxy}"

# 网段起始 IP，用来匹配 mihomo 加错的 /30 路由
_BASE_IP="${FAKE_IP_CIDR%/*}"
_BAD_ROUTE="$_BASE_IP/30"

# OpenWrt hotplug 会传 ACTION=add，systemd 不传任何环境变量；
# 仅在 hotplug 的非 add 场景退出
case "$ACTION" in
    add|"") ;;
    *) exit 0 ;;
esac

# 找一个真正存在的 TUN 接口。
# - hotplug 调用：$INTERFACE 已被上游 99-meta-route 校验过命中 $TUN_IFACES，
#   这里再做一次以防直接调用本脚本时 INTERFACE 被设成非 TUN 接口名；
#   如果不命中则直接放弃（不 fall through 到 wait 循环）。
# - systemd ExecStartPost 调用：$INTERFACE 未设置，进 wait 循环最多等 10 秒
#   等 TUN 接口出现。
_find_iface() {
    if [ -n "$INTERFACE" ]; then
        for _i in $TUN_IFACES; do
            [ "$INTERFACE" = "$_i" ] && { echo "$INTERFACE"; return 0; }
        done
        return 1
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

# 是否存在那条 /30 错路由（systemd 启动早期它还没出现）
_bad_route_exists() {
    ip route show "$_BAD_ROUTE" 2>/dev/null | grep -q .
}

# 等待 mihomo 把 /30 错路由加上来（最多 15 秒）。
# 在 OpenWrt 的 hotplug 场景下，/30 通常已经存在，第一次检查就会命中。
_wait_bad_route() {
    _try=0
    while [ "$_try" -lt 15 ]; do
        if _bad_route_exists; then
            return 0
        fi
        sleep 1
        _try=$((_try + 1))
    done
    return 1
}

_apply_route() {
    ip route del "$_BAD_ROUTE" 2>/dev/null
    ip route replace "$FAKE_IP_CIDR" dev "$1"
}

target=$(_find_iface) || {
    logger -t "$LOG_TAG" "TUN 接口 ($TUN_IFACES) 未上线，跳过路由配置"
    exit 0
}

if ! _wait_bad_route; then
    # 没等到 mihomo 加 /30：可能是 mihomo 这次没加错（已修复？）或者尚未连出去。
    # 仍然把 /12 路由加上去，保证 fake-ip 段能进 TUN
    ip route replace "$FAKE_IP_CIDR" dev "$target"
    logger -t "$LOG_TAG" "未观察到 $_BAD_ROUTE，仅设置 $FAKE_IP_CIDR -> $target"
    exit 0
fi

# 第一次修：删错路由 + 加正确网段
_apply_route "$target"
logger -t "$LOG_TAG" "fake-ip 路由 $FAKE_IP_CIDR -> $target（已修正 $_BAD_ROUTE）"

# 二次校验：mihomo 偶尔会在初始连接稳定前再次抢回 /30，等几秒再修一次
sleep 3
if _bad_route_exists; then
    _apply_route "$target"
    logger -t "$LOG_TAG" "$_BAD_ROUTE 被重复抢占，已再次修正"
fi
