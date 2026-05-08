#!/bin/sh
# 修复 mihomo TUN 路由 /30 bug：删错路由 + 加正确网段。
# 在 MP_TUN_IFACES 列表中找第一个真正存在的接口，存在就修；都不存在静默退出。
# 时序：systemd 调用前需自行 sleep 等 mihomo 起好，hotplug 触发时 TUN 已就绪。

# 本脚本所在目录
dir_self=$(dirname "$(readlink -f "$0")")
# env.conf 是硬性依赖
[ -f "$dir_self/env.conf" ] || { echo "缺少 $dir_self/env.conf" >&2; exit 1; }
# 加载全局变量
# shellcheck disable=SC1091
. "$dir_self/env.conf"
# 本地覆盖（可选）
# shellcheck disable=SC1091
[ -f "$dir_self/env.local.conf" ] && . "$dir_self/env.local.conf"

# 来自 hotplug 时只对 add 事件响应；其他调用方不传 ACTION，视为 add
[ "${ACTION:-add}" = "add" ] || exit 0

# 网段起始 IP，用来定位 mihomo 加错的 /30 路由
base_ip="${MP_FAKE_IP_CIDR%/*}"

# 在 MP_TUN_IFACES 中找第一个真正存在的接口
for iface in $MP_TUN_IFACES; do
    # 接口不存在就尝试下一个
    ip link show "$iface" >/dev/null 2>&1 || continue
    # 删 mihomo 加错的 /30 路由（不存在时静默）
    ip route del "$base_ip/30" 2>/dev/null
    # 加上配置中真正期望的 fake-ip 网段（存在则替换，不存在则新增）
    ip route replace "$MP_FAKE_IP_CIDR" dev "$iface"
    # 留痕便于 logread / journalctl 排查
    logger -t "$MP_LOG_TAG" "fake-ip 路由 $MP_FAKE_IP_CIDR -> $iface"
    exit 0
done

# 所有候选接口都不存在；记录后退出，由调用方决定是否重试
logger -t "$MP_LOG_TAG" "TUN 接口 ($MP_TUN_IFACES) 未上线，跳过路由配置"
