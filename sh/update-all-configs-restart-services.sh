#!/bin/sh
# 先用正在运行的 Core 完成全部下载，再按 AGH 停止→Core 重启→AGH 启动切换。
. "$(dirname "$(readlink -f "$0")")/common.sh"

if sh "$MP_INST_DIR/sh/update-all-configs.sh"; then
    echo_log "所有文件已下载，开始切换服务"
    agh_pending="$MP_AGH_DIR/agh.yaml.pending"
    [ -f "$agh_pending" ] \
        || { echo_log "缺少 AGH 待切换配置，取消服务重启"; exit 1; }
    mp_service_op stop agh \
        || { echo_log "AGH 停止失败，取消 Core 重启"; exit 1; }
    # AGH 运行期会回写 agh.yaml；停止完成后才用仓库模板完整覆盖。
    if ! mv "$agh_pending" "$MP_AGH_DIR/agh.yaml"; then
        echo_log "AGH 配置切换失败，取消 Core 重启"
        mp_service_op restart agh || :
        exit 1
    fi
    mp_service_op restart proxy_core \
        || { echo_log "Core 重启失败，AGH 保持停止"; exit 1; }
    mp_wait_core_ready 30 \
        || { echo_log "Core 未就绪，AGH 保持停止"; exit 1; }
    mp_service_op restart agh \
        || { echo_log "Core 已就绪，但 AGH 启动失败"; exit 1; }
    echo_log "Core / AGH 已按依赖顺序重启"
else
    echo_log "更新过程出错，跳过服务重启"
    exit 1
fi
