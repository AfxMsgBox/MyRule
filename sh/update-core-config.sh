#!/bin/sh
url_self="$MP_URL_UPDATE_CORE_CONFIG_SH"
. "$(dirname "$(readlink -f "$0")")/common.sh"

echo_log "更新代理内核 config.yaml"

# 拉取模板
download_file "$MP_URL_CORE_CONFIG" "$MP_CORE_DIR/config.new" \
    || { echo_log "下载 config.yaml 失败"; exit 1; }

# 替换 {MP_*} 占位符；MP_* 已被 env.conf 的 set -a 自动 export，awk 通过 ENVIRON 拿到
awk '{
    line = $0
    for (k in ENVIRON)
        if (substr(k, 1, 3) == "MP_") {
            ph = "{" k "}"
            while ((p = index(line, ph)) > 0)
                line = substr(line, 1, p-1) ENVIRON[k] substr(line, p+length(ph))
        }
    print line
}' "$MP_CORE_DIR/config.new" > "$MP_CORE_DIR/config.tmp" \
    && mv "$MP_CORE_DIR/config.tmp" "$MP_CORE_DIR/config.new"

# 备份旧文件，原子替换
[ -f "$MP_CORE_DIR/config.yaml" ] && mv -f "$MP_CORE_DIR/config.yaml" "$MP_CORE_DIR/config.yaml.bak"
mv -f "$MP_CORE_DIR/config.new" "$MP_CORE_DIR/config.yaml"
echo_log "config.yaml 已更新"
