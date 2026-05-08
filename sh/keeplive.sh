#!/bin/sh
# 周期保活：通过本地 HTTP 代理触发出口流量，让节点长连接保持活跃。
# 推荐 cron：*/5 * * * * sh /etc/proxy/sh/keeplive.sh
# 背景：https://github.com/vernesong/OpenClash/issues/2614

DIR_SCRIPT=$(dirname "$(readlink -f "$0")")
# shellcheck disable=SC1091
[ -f "$DIR_SCRIPT/env.conf" ] && . "$DIR_SCRIPT/env.conf"
PROXY_HTTP="${PROXY_HTTP:-http://127.0.0.1:7890}"

for url in https://www.google.com https://www.chatgpt.com; do
    curl --silent --max-time 5 --proxy "$PROXY_HTTP" -I "$url" >/dev/null 2>&1
done
