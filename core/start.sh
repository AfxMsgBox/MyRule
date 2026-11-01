#!/bin/sh
# auto-route:false 时维护完整 fake-IP 路由；/30 是 TUN 正常的接口网段。
# 所有监听/修复逻辑在此；systemd/procd 只负责进程生命周期。
case "${1:-}" in
    -h|--help)
        printf '%s\n' '用法：sh core/start.sh [--watch|--once]' \
            '  无参数   同时启动 Mihomo 和路由监听；任一异常退出交由服务管理器恢复。' \
            '  --watch  前台监听 Netlink，接口重建或路由变化后修复；供服务管理器调用。' \
            '  --once   检查并修复一次；接口尚未就绪时不操作。' \
            '配置读取安装目录的 core/config.yaml，无额外必填参数。'
        exit 0 ;;
    ''|--once|--watch) [ "$#" -le 1 ] || exit 2 ;;
    *) printf '%s\n' '未知参数，请使用 --help' >&2; exit 2 ;;
esac
. "$(dirname "$(readlink -f "$0" 2>/dev/null || printf '%s\n' "$0")")/../sh/common.sh"

# BusyBox ash 可能优先执行内置 ip；显式定位 PATH 中的 ip-full/iproute2。
route_ip_bin=$(
    IFS=:
    set -f
    for bin_dir in $PATH; do
        [ -n "$bin_dir" ] || bin_dir=.
        if [ -f "$bin_dir/ip" ] && [ -x "$bin_dir/ip" ]; then
            printf '%s\n' "$bin_dir/ip"; exit 0
        fi
    done
    exit 1
) || { printf '%s\n' '缺少 iproute2/ip-full' >&2; exit 1; }

route_config() {
    tun_device=$(mp_core_value tun device "$MP_CORE_DIR/config.yaml") || return 1
    case "$tun_device" in ''|*[!a-zA-Z0-9_-]*) return 1 ;; esac
    fake_ip_cidr=$(mp_core_fake_ip_cidr) || return 1
}

route_apply() (
    # 与手工 --once 串行；锁文件不删除，避免锁住不同 inode。
    exec 8>"$MP_CORE_DIR/.fake-ip-route.lock" || exit 1
    flock -x 8 || exit 1
    route_config || { logger -t MyProxy '无效的 TUN / fake-IP 配置'; exit 1; }
    link=$("$route_ip_bin" -o link show dev "$tun_device" 2>/dev/null) || exit 0
    printf '%s\n' "$link" | grep -Eq '<([^>]*,)?UP(,|>)' || exit 0
    # add 事件可能先于地址配置，等 address/link 事件，不用 sleep 猜时序。
    "$route_ip_bin" -4 -o address show dev "$tun_device" | grep -q ' inet ' || exit 0
    route_index=$(cat "/sys/class/net/$tun_device/ifindex") || exit 0
    route_boot=$(cat /proc/sys/kernel/random/boot_id) || exit 1
    route_record="$fake_ip_cidr $tun_device $route_index $route_boot"
    routes=$("$route_ip_bin" -4 route show table main exact "$fake_ip_cidr") || exit 1
    if printf '%s\n' "$routes" | awk -v cidr="$fake_ip_cidr" -v dev="$tun_device" '
        $1==cidr && $2=="dev" && $3==dev && !/ via / { found=1 }
        END { exit !found }'; then
        # 不认领外部预置的正确路由，也不因自己的路由事件重复写入。
        exit 0
    fi
    if ! "$route_ip_bin" -4 route replace "$fake_ip_cidr" dev "$tun_device"; then
        "$route_ip_bin" link show dev "$tun_device" >/dev/null 2>&1 || exit 0
        logger -t MyProxy "fake-IP 路由设置失败：$fake_ip_cidr -> $tun_device"
        exit 1
    fi
    # 若接口刚被重建，不把新接口误记为本次路由的所有者。
    [ "$(cat "/sys/class/net/$tun_device/ifindex" 2>/dev/null)" = "$route_index" ] || exit 0
    tmp=$(mktemp "$MP_CORE_DIR/.route.XXXXXX") || exit 1
    if ! printf '%s\n' "$route_record" > "$tmp" || ! mv "$tmp" "$MP_CORE_DIR/.fake-ip-route"; then
        rm -f "$tmp"
        logger -t MyProxy '保存路由卸载记录失败'
        exit 1
    fi
    logger -t MyProxy "fake-IP 路由已恢复：$fake_ip_cidr -> $tun_device (ifindex=$route_index)"
)

route_watch_cleanup() {
    trap '' HUP INT TERM
    if [ -n "${monitor_pid:-}" ]; then
        kill "$monitor_pid" 2>/dev/null || :
        wait "$monitor_pid" 2>/dev/null || :
    fi
    [ -z "${watch_dir:-}" ] || rm -rf "$watch_dir"
}

route_watch() {
    exec 9>"$MP_CORE_DIR/.fake-ip-watch.lock" || return 1
    flock -n 9 || { logger -t MyProxy 'fake-IP 事件监听已运行'; return 1; }
    watch_dir=$(mktemp -d) || return 1
    [ -n "${core_pid:-}" ] || trap route_watch_cleanup EXIT
    trap 'exit 0' HUP INT TERM
    mkfifo "$watch_dir/events" || return 1
    # 不用 dev 过滤：ip monitor 会把名称解析成旧 ifindex，漏掉同名重建。
    (exec 5>&- 9>&-; exec "$route_ip_bin" -o -4 monitor link address route) > "$watch_dir/events" 2>&1 &
    monitor_pid=$!
    exec 7<"$watch_dir/events"
    # 仅启动时等待订阅完成，再做快照，消除“快照与订阅之间”的漏事件窗口。
    # iproute2 的 RTNETLINK port ID 为进程 ID；无事件期间只阻塞 read。
    ready=0; attempts=0
    while [ "$attempts" -lt 100 ]; do
        if awk -v pid="$monitor_pid" '$2==0 && $3==pid && $4!="00000000" {ok=1}
            END {exit !ok}' /proc/net/netlink; then ready=1; break; fi
        kill -0 "$monitor_pid" 2>/dev/null || break
        attempts=$((attempts + 1))
        sleep 0.05
    done
    [ "$ready" -eq 1 ] || { logger -t MyProxy '无法订阅 Netlink，请检查 iproute2/ip-full'; return 1; }
    route_apply || return 1
    logger -t MyProxy 'fake-IP 路由事件监听已启动'
    while IFS= read -r event <&7; do
        case "$event" in
            *'No buffer space'*|*'Message truncated'*)
                logger -t MyProxy 'Netlink 事件丢失，重新订阅并核对路由'; return 1 ;;
        esac
        # 网页重载可能修改配置，每个事件按当前文件读取设备名和网段。
        route_config || return 1
        case "$event" in
            *" $tun_device:"*|*" $tun_device "*|*"$fake_ip_cidr"*) route_apply || return 1 ;;
        esac
    done
    logger -t MyProxy 'Netlink 监听中断，等待服务管理器重新启动'
    return 1
}

# CHLD 只检查两个直接子进程；全部使用 shell 内建，不递归创建子进程。
# /proc 是已要求的 Linux 接口。僵尸进程 kill -0 仍成功，必须核对状态。
core_child_event() {
    for watched_pid in ${core_pid:-} ${monitor_pid:-}; do
        if ! kill -0 "$watched_pid" 2>/dev/null; then
            exit 1
        fi
        if IFS=' ' read -r proc_pid proc_comm proc_state proc_rest < "/proc/$watched_pid/stat"; then
            case "$proc_state" in Z|X) exit 1 ;; esac
        else
            exit 1
        fi
    done
}

core_cleanup() {
    trap '' CHLD HUP INT TERM
    for pid in ${core_pid:-} ${monitor_pid:-}; do kill "$pid" 2>/dev/null || :; done
    for pid in ${core_pid:-} ${monitor_pid:-}; do wait "$pid" 2>/dev/null || :; done
    [ -z "${watch_dir:-}" ] || rm -rf "$watch_dir"
}

core_start() {
    core_pid=; monitor_pid=; watch_dir=
    [ -x "$MP_CORE_DIR/mihomo" ] || { logger -t MyProxy 'Core 不存在或不可执行'; return 1; }
    exec 5>"$MP_CORE_DIR/.start.lock" || return 1
    flock -n 5 || { logger -t MyProxy 'Core 启动器已运行'; return 1; }
    trap core_cleanup EXIT
    trap 'exit 0' HUP INT TERM
    (exec 5>&-; exec "$MP_CORE_DIR/mihomo" -d "$MP_CORE_DIR") &
    core_pid=$!
    trap core_child_event CHLD
    route_watch
    return 1
}

case "${1:-}" in
    --watch) route_watch ;;
    --once) route_apply ;;
    *) core_start ;;
esac
