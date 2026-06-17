#!/bin/sh
# 公共函数库。被各脚本 source 加载 env.conf + 提供工具函数。
# 不再做"任何"自更新；需要刷新脚本本身请显式跑 update-scripts.sh。
# 命名约定：MP_* 全局；小写本地。

# 通过脚本路径反推 $MP_INST_DIR（脚本约定在 sh/ 子目录，所以根 = ../..）
# 让 init.d/$0 不可靠的场景也能定位 env.conf 与 env.local.conf
_path_self=$(readlink -f "$0" 2>/dev/null || echo "$0")
MP_INST_DIR="${MP_INST_DIR:-$(dirname "$(dirname "$_path_self")")}"

if [ -f "$MP_INST_DIR/sh/env.conf" ]; then
    . "$MP_INST_DIR/sh/env.conf"
elif [ -f /etc/proxy/sh/env.conf ]; then
    . /etc/proxy/sh/env.conf
else
    echo "缺少 env.conf" >&2; exit 1
fi

# 日志：终端 + 系统 log
echo_log() {
    echo "$1"
    logger -t "$MP_LOG_TAG" -- "$1"
}

# 文件字节数；不存在返回 0
get_file_size() {
    [ -f "$1" ] && wc -c < "$1" | tr -d ' \n' || echo 0
}

# download_file <url> <dst> [verbose=true] [use_proxy] [min_size=8]
# verbose=true 时输出 url、完成时的字节数与耗时；false 完全静默
# use_proxy 缺省取 $MP_USE_PROXY；显式传 0/1 可覆盖
# 走代理失败自动回退直连；--fail 让 4xx/5xx 不被当成功；mktemp + mv 原子替换
download_file() {
    # 所有内部变量加 _df_ 前缀，避免污染调用方同名变量（POSIX sh 无 local）
    _df_url="$1"; _df_dst="$2"; _df_verbose="${3:-true}"
    _df_use_proxy="${4:-$MP_USE_PROXY}"; _df_min_size="${5:-8}"
    case "$_df_use_proxy" in 1|true|yes) _df_proxy="--proxy $MP_PROXY_HTTP" ;; *) _df_proxy="" ;; esac
    [ "$_df_verbose" = "true" ] && echo_log "下载 $_df_url"
    _df_t0=$(date +%s)
    _df_tmp=$(mktemp)
    # -L 跟进 302（GitHub releases 等都重定向到 S3），--max-time 放宽给大二进制
    curl --silent --show-error --fail -L --connect-timeout 10 --max-time 300 \
         --retry 2 --retry-delay 1 $_df_proxy "$_df_url" -o "$_df_tmp" >/dev/null 2>&1
    _df_rc=$?
    if [ "$_df_rc" -ne 0 ] && [ -n "$_df_proxy" ]; then
        [ "$_df_verbose" = "true" ] && echo_log "代理失败，回退直连"
        curl --silent --show-error --fail -L --connect-timeout 10 --max-time 300 \
             --retry 2 --retry-delay 1 "$_df_url" -o "$_df_tmp" >/dev/null 2>&1
        _df_rc=$?
    fi
    if [ "$_df_rc" -ne 0 ] || [ "$(get_file_size "$_df_tmp")" -le "$_df_min_size" ]; then
        rm -f "$_df_tmp"
        [ "$_df_verbose" = "true" ] && echo_log "下载失败"
        return 1
    fi
    [ "$_df_verbose" = "true" ] && echo_log "完成：$(get_file_size "$_df_tmp") 字节 / $(($(date +%s) - _df_t0))s"
    mv "$_df_tmp" "$_df_dst"
}

# OS 探测：MP_OS_TYPE 已设则尊重；探测后导出供子进程复用
mp_detect_os() {
    [ -n "$MP_OS_TYPE" ] && return 0
    if [ -f /etc/openwrt_release ] || grep -qs '^ID=.*openwrt' /etc/os-release; then
        MP_OS_TYPE=openwrt
    elif command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ]; then
        MP_OS_TYPE=systemd
    else
        return 1
    fi
    export MP_OS_TYPE
}

# mp_service_op <op> <svc...>   op: enable_start | restart | stop
# 按 MP_OS_TYPE 派发到 service / systemctl；逐个执行，失败仅 echo_log
mp_service_op() {
    mp_detect_os || { echo_log "未知 OS_TYPE，跳过 $*"; return 1; }
    _op=$1; shift
    for _svc in "$@"; do
        case "$MP_OS_TYPE-$_op" in
            openwrt-enable_start) service "$_svc" enable && service "$_svc" start ;;
            openwrt-restart)      service "$_svc" restart ;;
            openwrt-stop)         service "$_svc" stop ;;
            systemd-enable_start) systemctl enable --now "$_svc.service" ;;
            systemd-restart)      systemctl restart "$_svc.service" ;;
            systemd-stop)         systemctl stop "$_svc.service" ;;
            *) echo_log "未支持的操作 $MP_OS_TYPE-$_op"; return 1 ;;
        esac || echo_log "$_op $_svc 失败"
    done
}

# 模板渲染：用环境里同名 MP_* 变量替换文件中的 {MP_xxx} 占位符；原子替换
# mp_render_template <src> <dst>
mp_render_template() {
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
    }' "$1" > "$2.tmp" && mv "$2.tmp" "$2"
}

# 从缩进式 yaml 取顶层 map 下的子 key 列表
_yaml_extract_keys() {
    [ -f "$1" ] || return 1
    awk -v top="$2" '
    BEGIN { in_blk = 0; child_indent = -1 }
    $0 ~ "^" top ":[[:space:]]*$" { in_blk = 1; next }
    in_blk {
        if ($0 ~ /^[[:space:]]*$/) next
        if ($0 ~ /^[[:space:]]*#/) next
        match($0, /^[[:space:]]*/); indent = RLENGTH
        if (indent == 0) { in_blk = 0; next }
        if (child_indent < 0) child_indent = indent
        if (indent != child_indent) next
        line = $0; sub(/^[[:space:]]+/, "", line)
        if (match(line, /^[A-Za-z0-9_.-]+:/)) print substr(line, 1, RLENGTH-1)
    }
    ' "$1"
}
