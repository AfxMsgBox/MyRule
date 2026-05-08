#!/bin/sh
# 周期保活：通过本地 HTTP 代理触发出口流量，避免节点长连接 idle 断流。
# 推荐 cron：*/5 * * * * sh /etc/proxy/sh/keeplive.sh

# 本脚本所在目录
dir_self=$(dirname "$(readlink -f "$0")")
# env.conf 是硬性依赖
[ -f "$dir_self/env.conf" ] || { echo "缺少 $dir_self/env.conf" >&2; exit 1; }
# 加载全局变量
# shellcheck disable=SC1091
. "$dir_self/env.conf"
# 本地覆盖（可选）
# shellcheck disable=SC1091
[ -f "$dir_self/env.local.conf" ] && . "$dir_self/env.local.conf"

# 探测 google：HEAD 请求即可，5 秒超时，失败静默
curl --silent --max-time 5 --proxy "$MP_PROXY_HTTP" -I https://www.google.com >/dev/null 2>&1
# 探测 chatgpt：同上
curl --silent --max-time 5 --proxy "$MP_PROXY_HTTP" -I https://www.chatgpt.com >/dev/null 2>&1
