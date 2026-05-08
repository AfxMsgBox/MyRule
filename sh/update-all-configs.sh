#!/bin/sh
# 顶层编排：依次刷新 AGH dns.conf / core/config.yaml / 订阅与规则集。
# 任一步失败仍继续，最终 exit code 反映"是否全部成功"，
# 上层 update-all-configs-restart-services.sh 据此决定要不要重启服务。

# 自更新用：本脚本的 raw URL（来自 env 全局）
url_self="$MP_URL_UPDATE_ALL_CONFIGS_SH"
# 本脚本所在目录
dir_self=$(dirname "$(readlink -f "$0")")
# 加载公共函数与 env（env 缺失会在 common.sh 中报错退出）
# shellcheck disable=SC1091
. "$dir_self/common.sh"

# 用 flock 防止 cron 与手动同时跑互踩
exec 9>/var/lock/myproxy-update.lock 2>/dev/null
flock -n 9 2>/dev/null || { echo_log "另一个 update 实例在跑，退出"; exit 0; }

echo_log "============ update all configs ============"

# 累积 exit code；任一步失败置非 0
rc=0
# 第 1 步：AGH dns.conf
echo_log ">>> 更新 AdGuardHome dns.conf"
sh "$dir_self/update-agh-config.sh" --noupdate || rc=$?
# 第 2 步：代理内核 config.yaml
echo_log ">>> 更新代理内核 config.yaml"
sh "$dir_self/update-core-config.sh" --noupdate || rc=$?
# 第 3 步：订阅与规则集
echo_log ">>> 刷新订阅与规则集"
sh "$dir_self/update-proxy-rule.sh" --noupdate || rc=$?

# 总结输出
[ "$rc" -eq 0 ] && echo_log "============ all done ============" \
                || echo_log "============ done with errors (rc=$rc) ============"
exit "$rc"
