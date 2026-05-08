#!/bin/sh
# 顶层编排：依次刷新 AGH dns.conf / core/config.yaml / 订阅与规则集。
# 任一步失败仍继续，最终 exit code 反映"是否全部成功"，
# 上层 update-all-configs-restart-services.sh 据此决定要不要重启服务。

# 本脚本所在目录
DIR_SCRIPT=$(dirname "$(readlink -f "$0")")
# 自更新用：common.sh 据此把本脚本升级到最新
URL_SCRIPT="${REPO_RAW_URL:-https://raw.githubusercontent.com/AfxMsgBox/MyRule/main}/sh/update-all-configs.sh"

# 先把 common.sh 升级到最新（直接执行时它会自更新自己）
sh "$DIR_SCRIPT/common.sh"

# 加载公共函数与环境变量
# shellcheck disable=SC1091
. "$DIR_SCRIPT/common.sh"

# 用 flock 防止 cron 与手动同时跑互踩
exec 9>/var/lock/myproxy-update.lock 2>/dev/null
flock -n 9 2>/dev/null || { echo_log "另一个 update 实例在跑，退出"; exit 0; }

echo_log "============ update all configs ============"

# 累积 exit code；任一步失败置非 0
rc=0
# 第 1 步：AGH dns.conf
echo_log ">>> 更新 AdGuardHome dns.conf"
sh "$DIR_SCRIPT/update-agh-config.sh" --noupdate || rc=$?
# 第 2 步：代理内核 config.yaml
echo_log ">>> 更新代理内核 config.yaml"
sh "$DIR_SCRIPT/update-core-config.sh" --noupdate || rc=$?
# 第 3 步：订阅与规则集
echo_log ">>> 刷新订阅与规则集"
sh "$DIR_SCRIPT/update-proxy-rule.sh" --noupdate || rc=$?

# 总结输出
[ "$rc" -eq 0 ] && echo_log "============ all done ============" \
                || echo_log "============ done with errors (rc=$rc) ============"
exit "$rc"
