#!/bin/sh
# 拉取 core/config.yaml 模板，把 {MP_*} 占位符按当前环境替换后原子覆盖。
. "$(dirname "$(readlink -f "$0")")/common.sh"

echo_log "更新代理内核 config.yaml"
mkdir -p "$MP_CORE_DIR"

tpl=$(mktemp)
download_file "$MP_URL_CORE_CONFIG" "$tpl" \
    || { echo_log "下载 config.yaml 失败"; rm -f "$tpl"; exit 1; }

# 备份旧配置（保留一份）后原子替换
[ -f "$MP_CORE_DIR/config.yaml" ] && cp -f "$MP_CORE_DIR/config.yaml" "$MP_CORE_DIR/config.yaml.bak"
mp_render_template "$tpl" "$MP_CORE_DIR/config.yaml"
rm -f "$tpl"
echo_log "config.yaml 已更新"
