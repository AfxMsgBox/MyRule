#!/bin/sh
url_self="$MP_URL_UPDATE_CORE_CONFIG_SH"
. "$(dirname "$(readlink -f "$0")")/common.sh"

echo_log "更新代理内核 config.yaml"
mkdir -p "$MP_CORE_DIR"

# 拉取模板
download_file "$MP_URL_CORE_CONFIG" "$MP_CORE_DIR/config.new" \
    || { echo_log "下载 config.yaml 失败"; exit 1; }

# 扫描每行 {MP_xxx} 形式的占位符，用同名环境变量值替换；变量不存在则保留原样
# MP_* 已被 env.conf 的 set -a 自动 export，awk 通过 ENVIRON 拿到
awk '{
    out = ""
    while (match($0, /\{MP_[A-Za-z0-9_]+\}/)) {
        ph  = substr($0, RSTART, RLENGTH)
        key = substr(ph, 2, RLENGTH - 2)
        repl = (key in ENVIRON) ? ENVIRON[key] : ph
        out = out substr($0, 1, RSTART - 1) repl
        $0 = substr($0, RSTART + RLENGTH)
    }
    print out $0
}' "$MP_CORE_DIR/config.new" > "$MP_CORE_DIR/config.tmp" \
    && mv "$MP_CORE_DIR/config.tmp" "$MP_CORE_DIR/config.new"

# 备份旧文件，原子替换
[ -f "$MP_CORE_DIR/config.yaml" ] && mv -f "$MP_CORE_DIR/config.yaml" "$MP_CORE_DIR/config.yaml.bak"
mv -f "$MP_CORE_DIR/config.new" "$MP_CORE_DIR/config.yaml"
echo_log "config.yaml 已更新"
