#!/bin/sh
# 修复 mihomo TUN 路由 /30 bug：先删错路由，再加正确网段。
# 触发器：OpenWrt hotplug（99-meta-route）/ Debian systemd ExecStartPost。
. "$(dirname "$(readlink -f "$0")")/env.conf"

# hotplug 只对 add 事件响应；其它调用方不传 ACTION，视为 add
[ "${ACTION:-add}" = "add" ] || exit 0

# 从 mihomo 配置的 dns.fake-ip-range 读取并规范化为网络 CIDR。
# 配置不存在、字段缺失或 IPv4 CIDR 非法时回退到默认网段。
default_fake_ip_cidr="172.16.0.0/12"
config_yaml="$MP_CORE_DIR/config.yaml"
fake_ip_range=$(
    awk '
    BEGIN { in_dns = 0; dns_indent = -1 }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    {
        match($0, /^[[:space:]]*/); indent = RLENGTH
        line = $0; sub(/^[[:space:]]+/, "", line)
    }
    !in_dns && line ~ /^dns:[[:space:]]*(#.*)?$/ {
        in_dns = 1; dns_indent = indent; next
    }
    in_dns {
        if (indent <= dns_indent) { in_dns = 0; next }
        if (line ~ /^fake-ip-range:[[:space:]]*/) {
            sub(/^fake-ip-range:[[:space:]]*/, "", line)
            sub(/[[:space:]]*#.*/, "", line)
            gsub(/^[[:space:]"\047]+|[[:space:]"\047]+$/, "", line)
            print line
            exit
        }
    }
    ' "$config_yaml" 2>/dev/null
)

MP_FAKE_IP_CIDR=$(printf '%s\n' "$fake_ip_range" | awk -F/ '
    function fail() { exit 1 }
    NF != 2 || $2 !~ /^[0-9]+$/ || $2 < 0 || $2 > 32 { fail() }
    {
        n = split($1, octet, ".")
        if (n != 4) fail()
        for (i = 1; i <= 4; i++) {
            if (octet[i] !~ /^[0-9]+$/ || octet[i] < 0 || octet[i] > 255) fail()
            ip = ip * 256 + octet[i]
        }
        host_bits = 32 - $2
        block = 2 ^ host_bits
        network = int(ip / block) * block
        a = int(network / 16777216); network %= 16777216
        b = int(network / 65536);    network %= 65536
        c = int(network / 256);      d = network % 256
        printf "%d.%d.%d.%d/%d\n", a, b, c, d, $2
    }
')

if [ -z "$MP_FAKE_IP_CIDR" ]; then
    MP_FAKE_IP_CIDR="$default_fake_ip_cidr"
    logger -t "$MP_LOG_TAG" "未找到有效的 dns.fake-ip-range，使用默认值 $MP_FAKE_IP_CIDR"
fi

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
