#!/bin/sh
# 串跑三个配置刷新：agh dns.conf + core config.yaml + 订阅/规则集 PUT
. "$(dirname "$(readlink -f "$0")")/common.sh"

# 防并发：cron 与手动同跑互不踩
# 不要在此 exec 上加 2>/dev/null——它会把整个脚本（含子脚本）的 stderr 永久吞掉
exec 9>/var/lock/myproxy-update.lock
flock -n 9 2>/dev/null || { echo_log "另一个 update 实例在跑，退出"; exit 0; }

echo_log "============ update all configs ============"
rc=0
echo_log ">>> AGH dns.conf"
sh "$MP_INST_DIR/sh/update-agh-config.sh"    || rc=$((rc+1))
echo_log ">>> core config.yaml"
sh "$MP_INST_DIR/sh/update-core-config.sh"   || rc=$((rc+1))
echo_log ">>> 订阅与规则集"
sh "$MP_INST_DIR/sh/update-proxy-rule.sh"    || rc=$((rc+1))

[ "$rc" -eq 0 ] && echo_log "============ all done ============" \
                || echo_log "============ done with errors (rc=$rc) ============"
exit "$rc"
