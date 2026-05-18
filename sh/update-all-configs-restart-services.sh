#!/bin/sh
url_self="$MP_URL_UPDATE_ALL_CONFIGS_RESTART_SH"
. "$(dirname "$(readlink -f "$0")")/common.sh"

# 仅在全部更新成功时重启，避免坏配置上线
if sh "$dir_self/update-all-configs.sh"; then
    echo_log "重启 agh / proxy_core"
    if [ -f /etc/openwrt_release ] || grep -qs '^ID=.*openwrt' /etc/os-release 2>/dev/null; then
        service agh restart
        service proxy_core restart
    else
        systemctl restart agh.service
        systemctl restart proxy_core.service
    fi
else
    echo_log "更新过程出错，跳过服务重启"
    exit 1
fi
