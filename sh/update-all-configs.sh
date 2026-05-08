#!/bin/sh
# 顶层编排：把四类配置依次刷新一遍。被 update-all-configs-restart-services.sh 调用，
# 任一步失败时仍然继续，但最终 exit code 反映"是否全部成功"，便于上层决定要不要重启服务。

DIR_SCRIPT=$(dirname "$(readlink -f "$0")")
URL_SCRIPT="${REPO_RAW_URL:-https://raw.githubusercontent.com/AfxMsgBox/MyRule/main}/sh/update-all-configs.sh"

# 先单独把 common.sh 升级到最新（common.sh 直接执行时会用 _URL_COMMON_SH 自更新）
sh "$DIR_SCRIPT/common.sh"

# shellcheck disable=SC1091
. "$DIR_SCRIPT/common.sh"

_acquire_lock /var/lock/myrule-update.lock

echo_log "============ update all configs ============"

_overall_rc=0

_run_step "更新 AdGuardHome dns.conf" sh "$DIR_SCRIPT/update-agh-config.sh" --noupdate \
    || _overall_rc=$?

_run_step "更新代理内核 config.yaml"   sh "$DIR_SCRIPT/update-core-config.sh" --noupdate \
    || _overall_rc=$?

_run_step "刷新订阅与规则集"           sh "$DIR_SCRIPT/update-proxy-rule.sh" --noupdate \
    || _overall_rc=$?

if [ "$_overall_rc" -eq 0 ]; then
    echo_log "============ all done ============"
else
    echo_log "============ done with errors (rc=$_overall_rc) ============"
fi
exit "$_overall_rc"
