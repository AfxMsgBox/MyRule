#!/bin/sh
# 周期保活：通过本地代理触发出口流量，避免节点长连接 idle 断流
# 推荐 cron：*/5 * * * * sh /etc/proxy/sh/keeplive.sh
. "$(dirname "$(readlink -f "$0")")/env.conf"
curl --silent --max-time 5 --proxy "$MP_PROXY_HTTP" -I https://www.google.com   >/dev/null 2>&1
curl --silent --max-time 5 --proxy "$MP_PROXY_HTTP" -I https://www.chatgpt.com  >/dev/null 2>&1
