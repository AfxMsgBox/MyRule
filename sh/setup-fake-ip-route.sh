#!/bin/sh
# 修复 mihomo TUN 路由 /30 bug：先删错路由，再加正确网段。
# 触发器：OpenWrt hotplug（99-meta-route）/ Debian systemd ExecStartPost。
. "$(dirname "$(readlink -f "$0")")/common.sh"

# hotplug 只对 add 事件响应；其它调用方不传 ACTION，视为 add
[ "${ACTION:-add}" = "add" ] || exit 0

# 从 mihomo 配置的 dns.fake-ip-range 读取并规范化为网络 CIDR。
# DNS/fake-ip 是本方案的必需项：不另设默认值，也不检查 enable/enhanced-mode。
config_yaml="$MP_CORE_DIR/config.yaml"
# TUN 设备名也直接读取配置，避免另设一个可能失配的接口变量。
tun_device=$(mp_core_value tun device "$config_yaml" 2>/dev/null || :)
[ -n "$tun_device" ] || { logger -t MyProxy "Core 配置缺少 tun.device"; exit 1; }

fake_ip_cidr=$(mp_core_fake_ip_cidr "$config_yaml" 2>/dev/null || :)

if [ -z "$fake_ip_cidr" ]; then
    logger -t MyProxy "Core 配置缺少有效的 IPv4 dns.fake-ip-range"
    exit 1
fi

base_ip="${fake_ip_cidr%/*}"

# 仅操作配置里声明且已经创建的 TUN 设备。
if ip link show "$tun_device" >/dev/null 2>&1; then
    ip route del "$base_ip/30" 2>/dev/null
    ip route replace "$fake_ip_cidr" dev "$tun_device"
    logger -t MyProxy "fake-ip 路由 $fake_ip_cidr -> $tun_device"
    exit 0
fi

logger -t MyProxy "TUN 接口 ($tun_device) 未上线，跳过路由配置"
