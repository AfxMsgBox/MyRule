#!/bin/sh
# 全量更新后重启服务。仅在 update-all-configs.sh 全部成功时才重启，
# 避免半成品配置上线导致网络中断。

# 本脚本所在目录
DIR_SCRIPT=$(dirname "$(readlink -f "$0")")
# 自更新用
URL_SCRIPT="${REPO_RAW_URL:-https://raw.githubusercontent.com/AfxMsgBox/MyRule/main}/sh/update-all-configs-restart-services.sh"

# 加载公共函数与环境变量
# shellcheck disable=SC1091
. "$DIR_SCRIPT/common.sh"

# 全量更新；成功才走下面的重启分支
if sh "$DIR_SCRIPT/update-all-configs.sh"; then
    echo_log "重启 agh / proxy_core"
    # service 命令在 OpenWrt 与 Debian 上都可用
    service agh restart
    service proxy_core restart
else
    echo_log "更新过程出错，跳过服务重启（保留旧配置在线）"
    exit 1
fi
