#!/bin/sh
# update-all-configs 成功后重启 agh + proxy_core；任一步失败则跳过重启避免坏配上线。
. "$(dirname "$(readlink -f "$0")")/common.sh"

if sh "$MP_INST_DIR/sh/update-all-configs.sh"; then
    echo_log "重启 agh / proxy_core"
    mp_service_op restart agh proxy_core
else
    echo_log "更新过程出错，跳过服务重启"
    exit 1
fi
