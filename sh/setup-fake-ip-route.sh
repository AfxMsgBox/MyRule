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
    ip route del "$base_ip/30" 2>/dev/null || :
    if ! ip route replace "$fake_ip_cidr" dev "$tun_device"; then
        logger -t MyProxy "fake-ip 路由设置失败：$fake_ip_cidr -> $tun_device"
        exit 1
    fi
    # 记录本项目实际创建的路由及接口身份，卸载时只清理仍匹配的路由。
    route_index=$(cat "/sys/class/net/$tun_device/ifindex" 2>/dev/null) || route_index=
    route_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null) || route_boot=
    case "$route_boot" in ''|*[!a-f0-9-]*) route_index= ;; esac
    case "$route_index" in ''|*[!0-9]*)
        logger -t MyProxy '无法记录 TUN 接口身份；卸载将依靠接口销毁清理路由' ;;
        *)
            route_record=$(mktemp "$MP_CORE_DIR/.route.XXXXXX") || exit 1
            if ! printf '%s %s %s %s\n' "$fake_ip_cidr" "$tun_device" "$route_index" "$route_boot" > "$route_record" \
                || ! mv "$route_record" "$MP_CORE_DIR/.fake-ip-route"; then
                rm -f "$route_record"
                logger -t MyProxy '保存路由卸载记录失败'
                exit 1
            fi ;;
    esac
    logger -t MyProxy "fake-ip 路由 $fake_ip_cidr -> $tun_device"
    exit 0
fi

logger -t MyProxy "TUN 接口 ($tun_device) 未上线，跳过路由配置"
