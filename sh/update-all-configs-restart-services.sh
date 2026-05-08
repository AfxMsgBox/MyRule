#!/bin/sh
# 全量更新后重启服务。仅在 update-all-configs.sh 全部成功时才重启，
# 避免半成品配置被加载导致网络中断。

URL_SCRIPT="${REPO_RAW_URL:-https://raw.githubusercontent.com/AfxMsgBox/MyRule/main}/sh/update-all-configs-restart-services.sh"
DIR_SCRIPT=$(dirname "$(readlink -f "$0")")

# shellcheck disable=SC1091
. "$DIR_SCRIPT/common.sh"

if sh "$DIR_SCRIPT/update-all-configs.sh"; then
    echo_log "重启 agh / proxy_core"
    service agh restart
    service proxy_core restart
else
    echo_log "更新过程中发生错误，跳过服务重启（保留旧配置在线）"
    exit 1
fi
