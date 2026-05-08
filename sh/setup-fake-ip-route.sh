#!/bin/sh
# 修复 mihomo TUN 路由 /30 bug：删错路由 + 加正确网段。
# 在 ${TUN_IFACES} 列表中找第一个真正存在的接口，存在就修；都不存在静默退出。
# 时序：systemd 调用前需自行 sleep 等 mihomo 起好，hotplug 触发时 TUN 已就绪。

# 取本脚本所在目录，下一行据此 source 共享 env
DIR_SCRIPT=$(dirname "$(readlink -f "$0")")
# 加载 FAKE_IP_CIDR / TUN_IFACES / LOG_TAG
# shellcheck disable=SC1091
[ -f "$DIR_SCRIPT/env.conf" ] && . "$DIR_SCRIPT/env.conf"
# 兜底默认值，确保以下变量必定有值
FAKE_IP_CIDR="${FAKE_IP_CIDR:-172.16.0.0/12}"
TUN_IFACES="${TUN_IFACES:-utun Meta}"
LOG_TAG="${LOG_TAG:-MyProxy}"

# 来自 hotplug 时只对 add 事件响应；其他调用方不传 ACTION，视为 add
[ "${ACTION:-add}" = "add" ] || exit 0

# 网段起始 IP，用来定位 mihomo 加错的 /30 路由
BASE_IP="${FAKE_IP_CIDR%/*}"

# 在 TUN_IFACES 中找第一个真正存在的接口
for iface in $TUN_IFACES; do
    # 接口不存在就尝试下一个
    ip link show "$iface" >/dev/null 2>&1 || continue
    # 删 mihomo 加错的 /30 路由（不存在时静默）
    ip route del "$BASE_IP/30" 2>/dev/null
    # 加上配置中真正期望的 fake-ip 网段（存在则替换，不存在则新增）
    ip route replace "$FAKE_IP_CIDR" dev "$iface"
    # 留痕便于 logread / journalctl 排查
    logger -t "$LOG_TAG" "fake-ip 路由 $FAKE_IP_CIDR -> $iface"
    exit 0
done

# 所有候选接口都不存在；记录后退出，由调用方决定是否重试
logger -t "$LOG_TAG" "TUN 接口 ($TUN_IFACES) 未上线，跳过路由配置"
