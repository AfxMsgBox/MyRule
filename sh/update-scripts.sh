#!/bin/sh
# 唯一负责"更新脚本"的入口：拉仓库 tarball，只覆盖 sh/ 子树（含 env.conf /
# common.sh / 各 update-* / 自身 / sh/etc/* 等），然后 sed-patch sh/etc 路径占位，
# 并把"当初 inst 选了自启动 → /etc 下已有副本"的服务文件同步覆盖一份。
#
# 流程：
#   阶段 1（_MP_REEXEC 未设）：mp_fetch_repo_sh → exec 新版本
#   阶段 2（_MP_REEXEC=1）   ：sed-patch sh/etc + 同步 /etc（如存在）
#
# 自更新安全性：tarball 已 mktemp + mv 落地后再 exec；新进程从干净状态跑阶段 2，
# 即便旧进程的 shell 缓冲对自身脚本有任何疑虑，exec 后都不再相关。
. "$(dirname "$(readlink -f "$0")")/common.sh"

dir_sh="$MP_INST_DIR/sh"

if [ -z "$_MP_REEXEC" ]; then
    echo_log "============ self-update via tarball ============"
    mp_fetch_repo_sh "$dir_sh" || { echo_log "tarball 自更新失败，中止"; exit 1; }
    echo_log "self-update OK，exec 新版本继续"
    export _MP_REEXEC=1
    exec sh "$dir_sh/update-scripts.sh"
fi

# === 阶段 2：新版本已 exec 起来，做 sh/etc 路径替换与 /etc 同步 ===
echo_log "============ patch sh/etc & sync /etc ============"
mp_sync_etc_files if-exists \
    || { echo_log "sh/etc 处理或同步失败"; exit 1; }

echo_log "============ done ============"
