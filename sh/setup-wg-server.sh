#!/bin/sh
# 修复已有 WireGuard 的 IPv4 转发和 NAT；适用于 Debian/Ubuntu。
set -eu

fail() { printf '[失败] %s\n' "$*" >&2; exit 1; }
case "${1:-}" in
    -h|--help) echo '用法：sudo sh setup-wg-server.sh（自动检测运行中的 WG 接口、网段和出口，无需参数）'; exit 0 ;;
    '') ;;
    *) fail '不接受配置参数；使用 --help 查看用法' ;;
esac
[ "$#" -eq 0 ] || fail '不接受配置参数'
[ "$(id -u)" = 0 ] || fail '请以 root 运行'
[ -d /run/systemd/system ] || fail '仅支持 systemd Linux'
for tool in ip wg wg-quick nft sysctl systemctl; do
    command -v "$tool" >/dev/null || fail "缺少 $tool，请安装 wireguard-tools nftables iproute2"
done

wg_if=$(wg show interfaces)
wan=$(ip -4 route show default | awk '{for(i=1;i<NF;i++) if($i=="dev") print $(i+1)}' | sort -u)
for name in "$wg_if" "$wan"; do
    case "$name" in ''|*[!a-zA-Z0-9_.-]*) fail '需要一个运行中的 WG 接口和唯一默认出口' ;; esac
done
[ -f "/etc/wireguard/$wg_if.conf" ] || fail "缺少 /etc/wireguard/$wg_if.conf，无法配置 WG 开机启动"
systemctl cat "wg-quick@$wg_if.service" >/dev/null || fail "缺少 wg-quick systemd 服务"
[ "$wg_if" != "$wan" ] || fail 'WG 接口不能同时是默认出口'
subnet=$(ip -4 route show dev "$wg_if" proto kernel scope link | awk '$1 ~ /^[0-9.]+\/[0-9]+$/ {print $1}' | sort -u)
case "$subnet" in ''|*[!0-9./]*) fail '无法确定唯一 WG IPv4 网段，请检查接口地址和路由' ;; esac

rules=/etc/nftables.d/myrule-wg.nft
include='include "/etc/nftables.d/myrule-wg.nft"'
for file in /etc/nftables.d "$rules" /etc/nftables.conf /etc/sysctl.d/99-zz-myrule-wg.conf; do
    [ ! -L "$file" ] || fail "拒绝覆盖符号链接：$file"
done
if [ -e "$rules" ]; then
    grep -qxF '# MyRule WG NAT' "$rules" || fail "同名文件不属于此脚本：$rules"
fi
tmp=$(mktemp -d)
trap 'rc=$?; rm -rf "$tmp"; if [ "$rc" -ne 0 ]; then echo "[失败] 修复未完成，请检查上方错误" >&2; fi' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if nft list table ip myrule_wg > "$tmp/current" 2>/dev/null; then
    grep -qF 'comment "MyRule WG NAT"' "$tmp/current" || fail '同名 NAT 表已被其它配置使用'
fi
cat > "$tmp/nat" <<RULES
# MyRule WG NAT
add table ip myrule_wg { comment "MyRule WG NAT"; }
flush table ip myrule_wg
add chain ip myrule_wg postrouting { type nat hook postrouting priority srcnat; policy accept; }
add rule ip myrule_wg postrouting iifname "$wg_if" oifname "$wan" ip saddr $subnet counter masquerade
RULES
nft -c -f "$tmp/nat"
printf '[信息] %s（%s）→ %s\n' "$wg_if" "$subnet" "$wan"

# 只加载自己的 NAT 表；不重载整个防火墙，不重启 WireGuard。
mkdir -p /etc/nftables.d
cp "$tmp/nat" "$rules"
chmod 644 "$rules"
if ! grep -qxF "$include" /etc/nftables.conf 2>/dev/null; then
    [ ! -f /etc/nftables.conf ] || cp -p /etc/nftables.conf /etc/nftables.conf.bak-myrule-wg
    printf '\n%s\n' "$include" >> /etc/nftables.conf
fi
printf 'net.ipv4.ip_forward = 1\n' > /etc/sysctl.d/99-zz-myrule-wg.conf
sysctl -p /etc/sysctl.d/99-zz-myrule-wg.conf
nft -f "$rules"
systemctl enable nftables "wg-quick@$wg_if.service"
echo '[成功] IPv4 转发和 NAT 已持久化，WireGuard 已设置开机启动；当前接口未重启，请从客户端复测。'
