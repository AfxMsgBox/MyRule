#!/bin/sh
# 周期保活：通过本地 HTTP 代理触发出口流量，避免节点长连接 idle 断流
# 推荐 cron：*/5 * * * * sh /etc/proxy/sh/keeplive.sh

# 取得脚本所在目录，下一行据此 source 本地的 env.conf
DIR_SCRIPT=$(dirname "$(readlink -f "$0")")
# 加载 PROXY_HTTP 等共享变量；env.conf 不存在则使用下面的兜底默认值
# shellcheck disable=SC1091
[ -f "$DIR_SCRIPT/env.conf" ] && . "$DIR_SCRIPT/env.conf"
# 兜底默认：本地 mihomo mixed-port
PROXY_HTTP="${PROXY_HTTP:-http://127.0.0.1:7890}"

# 探测 google：HEAD 请求即可，5 秒超时，失败静默
curl --silent --max-time 5 --proxy "$PROXY_HTTP" -I https://www.google.com >/dev/null 2>&1
# 探测 chatgpt：同上
curl --silent --max-time 5 --proxy "$PROXY_HTTP" -I https://www.chatgpt.com >/dev/null 2>&1
