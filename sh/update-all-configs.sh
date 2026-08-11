#!/bin/sh
# 串跑所有文件刷新：Core 配置/providers + AGH 配置/dns.conf/filters。
. "$(dirname "$(readlink -f "$0")")/common.sh"

echo_log "============ update all configs ============"

# Core 配置在所有下载结束前保持不变，确保公共下载函数始终使用正在运行的
# 本机 Core 代理。AGH 配置也先生成待切换文件，避免被运行中的 AGH 回写。
core_pending="$MP_CORE_DIR/config.yaml.pending"
agh_pending="$MP_AGH_DIR/agh.yaml.pending"
rm -f "$core_pending" "$agh_pending"

rc=0
echo_log ">>> core config.yaml（暂存）"
sh "$MP_INST_DIR/sh/update-core-config.sh" "$core_pending" || rc=1
if [ "$rc" -eq 0 ]; then
    echo_log ">>> AGH agh.yaml（待服务停止后切换）"
    mp_prepare_agh_config "$agh_pending" "$core_pending" || rc=1
fi
if [ "$rc" -eq 0 ]; then
    echo_log ">>> AGH dns.conf"
    sh "$MP_INST_DIR/sh/update-agh-config.sh" "$core_pending" || rc=1
fi
if [ "$rc" -eq 0 ]; then
    mv "$core_pending" "$MP_CORE_DIR/config.yaml" || rc=1
fi

if [ "$rc" -eq 0 ]; then
    echo_log "AGH 配置已暂存：$agh_pending"
    echo_log "============ all downloads done ============"
else
    rm -f "$core_pending" "$agh_pending"
    echo_log "============ done with errors，正式 config.yaml/agh.yaml 保持不变 ============"
fi
exit "$rc"
