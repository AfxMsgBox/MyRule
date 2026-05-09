#!/bin/sh
# 修复 mihomo TUN 路由 /30 bug：先删错路由，再加正确网段。
# 触发器：OpenWrt hotplug（99-meta-route）/ Debian systemd ExecStartPost。
. "$(dirname "$(readlink -f "$0")")/env.conf"

# hotplug 只对 add 事件响应；其它调用方不传 ACTION，视为 add
[ "${ACTION:-add}" = "add" ] || exit 0

base_ip="${MP_FAKE_IP_CIDR%/*}"

# 在 MP_TUN_IFACES 中找第一个真正存在的接口
for iface in $MP_TUN_IFACES; do
    ip link show "$iface" >/dev/null 2>&1 || continue
    ip route del "$base_ip/30" 2>/dev/null
    ip route replace "$MP_FAKE_IP_CIDR" dev "$iface"
    logger -t "$MP_LOG_TAG" "fake-ip 路由 $MP_FAKE_IP_CIDR -> $iface"
    exit 0
done

logger -t "$MP_LOG_TAG" "TUN 接口 ($MP_TUN_IFACES) 未上线，跳过路由配置"
