#!/bin/sh
# 拉取最新 core/config.yaml 模板，用本地 local.conf 替换 {占位符}，
# 替换完成后做粗略 yaml 完整性校验，校验失败保留旧 config.yaml 不替换。

# 自更新用：本脚本的 raw URL（来自 env 全局）
url_self="$MP_URL_UPDATE_CORE_CONFIG_SH"
# 本脚本所在目录
dir_self=$(dirname "$(readlink -f "$0")")
# 加载公共函数与 env
# shellcheck disable=SC1091
. "$dir_self/common.sh"

echo_log "更新代理内核 config.yaml"

# 没写本地敏感参数就跳过（首次部署提示）
[ -f "$MP_CORE_DIR/local.conf" ] || { echo_log "未找到 $MP_CORE_DIR/local.conf，跳过"; exit 0; }

# 拉取模板到 .new；失败直接退出
download_file "$MP_URL_CORE_CONFIG" "$MP_CORE_DIR/config.new" 1 \
    || { echo_log "下载 config.yaml 失败"; exit 1; }

# 替换 {KEY} 占位符；失败清理后退出
replace_strings_from_config "$MP_CORE_DIR/local.conf" "$MP_CORE_DIR/config.new" \
    || { echo_log "占位符替换失败"; rm -f "$MP_CORE_DIR/config.new"; exit 1; }

# 粗略校验 1：必须含 proxies / proxy-providers / rules 三个顶层段
grep -q '^proxies:' "$MP_CORE_DIR/config.new" \
    && grep -q '^proxy-providers:' "$MP_CORE_DIR/config.new" \
    && grep -q '^rules:' "$MP_CORE_DIR/config.new" \
    || { echo_log "校验失败：缺少关键段落，放弃替换"; rm -f "$MP_CORE_DIR/config.new"; exit 1; }

# 粗略校验 2：不能残留 {占位符}（残留=local.conf 缺键）
if grep -q '{[A-Za-z_][A-Za-z0-9_]*}' "$MP_CORE_DIR/config.new"; then
    echo_log "校验失败：仍有未替换的占位符（local.conf 缺键？）"
    grep -n '{[A-Za-z_][A-Za-z0-9_]*}' "$MP_CORE_DIR/config.new" | head -5
    rm -f "$MP_CORE_DIR/config.new"
    exit 1
fi

# 校验通过：旧文件备份成 .bak，再原子替换
[ -f "$MP_CORE_DIR/config.yaml" ] && mv -f "$MP_CORE_DIR/config.yaml" "$MP_CORE_DIR/config.yaml.bak"
mv -f "$MP_CORE_DIR/config.new" "$MP_CORE_DIR/config.yaml"
echo_log "config.yaml 已更新"
