#!/bin/sh
# 先用正在运行的 Core 完成全部下载，再按 AGH 停止→Core 重启→AGH 启动切换。
. "$(dirname "$(readlink -f "$0" 2>/dev/null || printf '%s\n' "$0")")/common.sh"

if sh "$MP_INST_DIR/sh/update-all-configs.sh"; then
    echo_log "所有文件已下载，开始切换服务"
    mp_activate_configs restart || exit 1
else
    echo_log "更新过程出错，跳过服务重启"
    exit 1
fi
