#!/bin/sh
# 更新现有 Core 的 providers 及 AGH 资源；用户 Core 配置始终只读。
. "$(dirname "$(readlink -f "$0" 2>/dev/null || printf '%s\n' "$0")")/common.sh"
agh_pending="$MP_AGH_DIR/agh.yaml.pending"
rm -f "$agh_pending" || exit 1
if mp_core_validate && mp_fetch_core_providers &&
    mp_prepare_agh_config "$agh_pending" &&
    sh "$MP_INST_DIR/sh/update-agh-config.sh"; then
    echo_log '订阅、规则及 AGH 配置已准备；Core config.yaml 保持不变'
else
    rm -f "$agh_pending"
    echo_log '资源更新失败；Core config.yaml 保持不变'
    exit 1
fi
