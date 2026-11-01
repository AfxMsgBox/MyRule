#!/bin/sh
# 第一阶段同步 sh/ 并 exec 新版；第二阶段同步 core/start.sh、生成系统服务、
# 调用独立迁移脚本清理旧机制，再按指纹重启原本运行的服务。
. "$(dirname "$(readlink -f "$0" 2>/dev/null || printf '%s\n' "$0")")/common.sh"

dir_sh="$MP_INST_DIR/sh"

if [ -z "$_MP_REEXEC" ]; then
    echo_log "============ self-update via tarball ============"
    mp_fetch_repo_sh "$dir_sh" || { echo_log "tarball 自更新失败，中止"; exit 1; }
    echo_log "self-update OK，exec 新版本继续"
    export _MP_REEXEC=1
    exec sh "$dir_sh/update-scripts.sh"
fi

# 第二阶段：新版本负责启动器更新、服务生成与旧版本迁移。
echo_log "============ sync core/start.sh & generate services ============"
mp_sync_core_start || { echo_log "Core 启动器同步失败"; exit 1; }
mp_sync_etc_files if-exists \
    || { echo_log "系统服务生成或迁移失败"; exit 1; }
mp_restart_updated_services \
    || { echo_log '脚本已更新，但服务生效失败，请检查 MyProxy 日志'; exit 1; }

echo_log "============ done ============"
