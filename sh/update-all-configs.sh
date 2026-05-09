#!/bin/sh
url_self="$MP_URL_UPDATE_ALL_CONFIGS_SH"
. "$(dirname "$(readlink -f "$0")")/common.sh"

# 防并发：cron 与手动同跑互不踩
exec 9>/var/lock/myproxy-update.lock 2>/dev/null
flock -n 9 2>/dev/null || { echo_log "另一个 update 实例在跑，退出"; exit 0; }

echo_log "============ update all configs ============"
rc=0
echo_log ">>> AGH dns.conf"
sh "$dir_self/update-agh-config.sh" --autoupdate=false || rc=$?
echo_log ">>> core config.yaml"
sh "$dir_self/update-core-config.sh" --autoupdate=false || rc=$?
echo_log ">>> 订阅与规则集"
sh "$dir_self/update-proxy-rule.sh" --autoupdate=false || rc=$?

[ "$rc" -eq 0 ] && echo_log "============ all done ============" \
                || echo_log "============ done with errors (rc=$rc) ============"
exit "$rc"
