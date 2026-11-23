#!/bin/sh
# 兼容旧维护入口：只更新现有 Core 配置引用的 providers，绝不生成配置。
. "$(dirname "$(readlink -f "$0" 2>/dev/null || printf '%s\n' "$0")")/common.sh"
[ "$#" -eq 0 ] || { echo_log '此入口不再接受输出路径，也不再生成 Core 配置'; exit 2; }
mp_core_validate && mp_fetch_core_providers
