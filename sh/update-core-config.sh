#!/bin/sh
# 拉取最新 core/config.yaml 模板，用本地 local.conf 替换 {占位符}，
# 替换完成后做一轮粗略 yaml 校验，校验失败则保留旧配置。

URL_SCRIPT="${REPO_RAW_URL:-https://raw.githubusercontent.com/AfxMsgBox/MyRule/main}/sh/update-core-config.sh"
DIR_SCRIPT=$(dirname "$(readlink -f "$0")")

# shellcheck disable=SC1091
. "$DIR_SCRIPT/common.sh"

URL_CONFIG="${REPO_RAW_URL:-https://raw.githubusercontent.com/AfxMsgBox/MyRule/main}/core/config.yaml"
DIR_CONFIG="${CORE_DIR:-$DIR_SCRIPT/../core}"

echo_log "更新代理内核 config.yaml"

if [ ! -f "$DIR_CONFIG/local.conf" ]; then
    echo_log "未找到 $DIR_CONFIG/local.conf，跳过（首次部署请补齐占位符再运行本脚本）"
    exit 0
fi

if ! download_file "$URL_CONFIG" "$DIR_CONFIG/config.new" 1; then
    echo_log "下载 config.yaml 失败"
    exit 1
fi

if ! replace_strings_from_config "$DIR_CONFIG/local.conf" "$DIR_CONFIG/config.new"; then
    echo_log "占位符替换失败"
    rm -f "$DIR_CONFIG/config.new"
    exit 1
fi

# 粗略 yaml 完整性检查：必须包含几个关键顶层 key，且没有未替换的 {占位符}
if ! grep -q '^proxies:' "$DIR_CONFIG/config.new" \
   || ! grep -q '^proxy-providers:' "$DIR_CONFIG/config.new" \
   || ! grep -q '^rules:' "$DIR_CONFIG/config.new"; then
    echo_log "校验失败：config.new 缺少关键段落，放弃替换"
    rm -f "$DIR_CONFIG/config.new"
    exit 1
fi
if grep -q '{[A-Za-z_][A-Za-z0-9_]*}' "$DIR_CONFIG/config.new"; then
    echo_log "校验失败：仍有未替换的占位符，请检查 local.conf"
    grep -n '{[A-Za-z_][A-Za-z0-9_]*}' "$DIR_CONFIG/config.new" | head -5
    rm -f "$DIR_CONFIG/config.new"
    exit 1
fi

# 校验通过，原子替换并保留备份
[ -f "$DIR_CONFIG/config.yaml" ] && mv -f "$DIR_CONFIG/config.yaml" "$DIR_CONFIG/config.yaml.bak"
mv -f "$DIR_CONFIG/config.new" "$DIR_CONFIG/config.yaml"

echo_log "config.yaml 已更新"
