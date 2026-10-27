#!/bin/sh
# Linux / macOS / BusyBox 共用的小工具；无系统改动。

mp_realpath() (
    _rp=$1; _rp_count=0
    while :; do
        _rp_dir=$(CDPATH= cd -P -- "$(dirname "$_rp")" 2>/dev/null && pwd -P) || exit 1
        _rp="$_rp_dir/$(basename "$_rp")"
        [ -L "$_rp" ] || { printf '%s\n' "$_rp"; exit 0; }
        _rp_count=$((_rp_count + 1)); [ "$_rp_count" -le 40 ] || exit 1
        _rp_link=$(readlink "$_rp") || exit 1
        case "$_rp_link" in /*) _rp=$_rp_link ;; *) _rp="$_rp_dir/$_rp_link" ;; esac
    done
)

# 从标准输入计算 SHA-256。macOS 自带 shasum，Linux/BusyBox 使用 sha256sum。
mp_sha256() (
    if command -v sha256sum >/dev/null 2>&1; then _hash=$(sha256sum) || exit 1
    elif command -v shasum >/dev/null 2>&1; then _hash=$(shasum -a 256) || exit 1
    else exit 1
    fi
    _hash=${_hash%% *}
    case "$_hash" in ''|*[!0-9a-f]*) exit 1 ;; esac
    [ "${#_hash}" -eq 64 ] || exit 1
    printf '%s\n' "$_hash"
)

mp_cache_read() {
    _mcr_key=$(printf '%s' "$1" | mp_sha256) || return 1
    _mcr_cache="$_MP_RESOURCE_DIR/$_mcr_key"
    [ -f "$_mcr_cache" ] && [ ! -L "$_mcr_cache" ] && [ -f "$_mcr_cache.sha256" ] \
        || { echo_log '安装包缺少所需资源，停止安装'; return 1; }
    _mcr_hash=$(mp_sha256 < "$_mcr_cache") || return 1
    [ "$_mcr_hash" = "$(cat "$_mcr_cache.sha256")" ] && [ -n "$_mcr_hash" ] \
        && [ "$(wc -c < "$_mcr_cache")" -gt "${3:-8}" ] \
        || { echo_log '安装包资源校验失败'; return 1; }
    mkdir -p "$(dirname "$2")" || return 1
    _mcr_stage=$(mktemp "$2.cache.XXXXXX") || return 1
    if ! cp "$_mcr_cache" "$_mcr_stage" || ! mv "$_mcr_stage" "$2"; then
        rm -f "$_mcr_stage"; return 1
    fi
}

mp_cache_write() {
    [ -n "${_MP_CACHE_WRITE:-}" ] || return 0
    _mcw_key=$(printf '%s' "$1" | mp_sha256) || return 1
    [ -n "$_mcw_key" ] || return 1
    mkdir -p "$_MP_CACHE_WRITE" || return 1
    cp "$2" "$_MP_CACHE_WRITE/$_mcw_key" &&
        mp_sha256 < "$2" > "$_MP_CACHE_WRITE/$_mcw_key.sha256"
}

# BEGIN shared HTTP transport (also embedded in standalone inst.sh)
# Resolve a writable private file without following a file symlink.
mp_private_path() (
    [ -n "$1" ] && [ ! -L "$1" ] && { [ ! -e "$1" ] || [ -f "$1" ]; } || exit 1
    case "$1" in */*) _pp_parent=${1%/*}; _pp_parent=${_pp_parent:-/} ;; *) _pp_parent=. ;; esac
    _pp_dir=$(CDPATH= cd -- "$_pp_parent" 2>/dev/null && pwd -P) || exit 1
    printf '%s/%s\n' "$_pp_dir" "${1##*/}"
)

mp_init_log() {
    MP_LOG_FILE=$(mp_private_path "$1") \
        || { printf '%s\n' '日志路径无效，请指定现有目录中的普通文件' >&2; return 1; }
    if [ -n "${INST_FILL_FILE:-}" ] && [ "$(mp_private_path "$INST_FILL_FILE")" = "$MP_LOG_FILE" ]; then
        printf '%s\n' '配置文件与日志文件不能使用同一路径' >&2; return 1
    fi
    (umask 077; : >> "$MP_LOG_FILE") \
        || { printf '%s\n' '无法写入下载命令日志' >&2; return 1; }
    if command -v chmod >/dev/null 2>&1; then chmod 600 "$MP_LOG_FILE" || return 1; fi
    export MP_LOG_FILE
}

mp_log_event() (
    [ -n "${MP_LOG_FILE:-}" ] && [ -f "$MP_LOG_FILE" ] && [ ! -L "$MP_LOG_FILE" ] || exit 0
    _le_time=$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || printf unknown)
    printf '[%s] %s\n' "$_le_time" "$*" >> "$MP_LOG_FILE"
)

mp_download_message() { printf '%s\n' "$*" >&2; mp_log_event "$*"; }

# Optional wizard defaults are JSON data, never sourced or evaluated as shell code.
mp_fill_init() {
    [ -n "${INST_FILL_FILE:-}" ] || return 0
    INST_FILL_FILE=$(mp_private_path "$INST_FILL_FILE") \
        || { mp_download_message '交互配置文件路径无效'; return 1; }
    [ "$INST_FILL_FILE" != "${MP_LOG_FILE:-}" ] \
        || { printf '%s\n' '配置文件与日志文件不能使用同一路径' >&2; return 1; }
    if [ ! -e "$INST_FILL_FILE" ]; then
        (umask 077; printf '{}\n' > "$INST_FILL_FILE") || return 1
    fi
    jq -e 'type=="object" and all(.[]; type=="string" and (explode | index(0)==null))' \
        "$INST_FILL_FILE" >/dev/null 2>&1 \
        || { mp_download_message '交互配置必须为 JSON 对象，字段值须为不含空字符的字符串'; return 1; }
    chmod 600 "$INST_FILL_FILE" || return 1
}

mp_fill_default() {
    if [ -n "${INST_FILL_FILE:-}" ]; then
        jq -r --arg key "$1" --arg fallback "$2" 'if has($key) then .[$key] else $fallback end' "$INST_FILL_FILE"
    else printf '%s\n' "$2"; fi
}

mp_fill_save() (
    [ -n "${INST_FILL_FILE:-}" ] || exit 0
    umask 077
    _fs_tmp=$(mktemp "$INST_FILL_FILE.tmp.XXXXXX") || exit 1
    trap 'rm -f -- "$_fs_tmp"' EXIT
    jq --arg key "$1" --arg value "$2" '.[$key]=$value' "$INST_FILL_FILE" > "$_fs_tmp" \
        && chmod 600 "$_fs_tmp" && mv "$_fs_tmp" "$INST_FILL_FILE" \
        || { mp_download_message '保存交互配置失败'; exit 1; }
    mp_log_event "交互配置已更新字段：$1"
)

# Keep public project download paths; private resource paths/queries may contain tokens.
mp_log_url() (
    _lu_url=$1; _lu_scheme=${1%%://*}; _lu_tail=${1#*://}
    _lu_host=${_lu_tail%%[/?#]*}
    case "$_lu_host" in *@*) _lu_host="<redacted>@${_lu_host##*@}" ;; esac
    _lu_base=${_lu_url%%\?*}; _lu_base=${_lu_base%%\#*}
    if [ "${2:-}" = proxy ]; then
        _lu_safe="$_lu_scheme://$_lu_host"
    else
        case "$_lu_base" in
            https://github.com/AfxMsgBox/MyRule/*|https://codeload.github.com/AfxMsgBox/MyRule/*|https://api.github.com/repos/AfxMsgBox/MyRule/*|https://raw.githubusercontent.com/AfxMsgBox/MyRule/*|\
            https://github.com/MetaCubeX/mihomo/*|https://api.github.com/repos/MetaCubeX/mihomo/*|https://github.com/MetaCubeX/metacubexd/*|https://github.com/AdguardTeam/AdGuardHome/*|\
            https://adguardteam.github.io/HostlistsRegistry/assets/*|https://raw.githubusercontent.com/Loyalsoldier/clash-rules/*)
                _lu_safe=$_lu_base ;;
            *) _lu_safe="$_lu_scheme://$_lu_host/<redacted>" ;;
        esac
    fi
    case "$_lu_url" in *\?*) _lu_safe="$_lu_safe?<redacted>" ;; esac
    case "$_lu_url" in *\#*) _lu_safe="$_lu_safe#<redacted>" ;; esac
    printf '%s' "$_lu_safe"
)

# Shell-quote arguments without eval or external tools (also used before dependency setup).
mp_log_command() (
    mp_init_log "${MP_LOG_FILE:-${INST_ENTRY_DIR:-${MP_INST_DIR:-.}/sh}/myrule.inst.log}" || exit 1
    exec >> "$MP_LOG_FILE" || exit 1
    mp_log_event '执行命令（敏感值已脱敏）'
    printf '  [命令，敏感值已脱敏]'
    _lc_kind=
    for _lc_arg do
        _lc_next=
        case "$_lc_arg" in --proxy) _lc_next=proxy ;; esac
        case "$_lc_arg" in
            http://*|https://*|socks5://*|socks5h://*) _lc_arg=$(mp_log_url "$_lc_arg" "$_lc_kind") ;;
            'Authorization:'*) _lc_arg='Authorization: <redacted>' ;;
        esac
        printf " '"
        while :; do
            case "$_lc_arg" in
                *\'*) printf '%s' "${_lc_arg%%\'*}" "'\\''"; _lc_arg=${_lc_arg#*\'} ;;
                *) printf "%s'" "$_lc_arg"; break ;;
            esac
        done
        _lc_kind=$_lc_next
    done
    printf '\n'
)

mp_run_download_command() {
    mp_log_command "$@" || return 1
    _rd_rc=0; "$@" || _rd_rc=$?
    mp_log_event "命令结束：$1，退出码 $_rd_rc"
    return "$_rd_rc"
}

# Render only byte counts and response size, never raw curl output or headers.
mp_download_progress() {
    _dp_line=$(awk -v bytes="$1" -v seconds="$2" -v done="$3" '
        /^HTTP\// { total=0; gsub(/\r/, "", $2); ok=($2 ~ /^2[0-9][0-9]$/) }
        tolower($1)=="content-length:" && ok {
            gsub(/\r/, "", $2); if ($2 ~ /^[0-9]+$/) total=$2+0
        }
        END {
            rate=bytes/(seconds>0 ? seconds : 1)/1048576
            if (total>0) {
                pct=int(bytes*100/total); if(pct>100) pct=100
                bar=""; for(i=0;i<20;i++) bar=bar (i<int(pct/5) ? "#" : "-")
                printf "  [%s] %3d%%  %.2f/%.2f MiB", bar,pct,bytes/1048576,total/1048576
            } else printf "  已下载 %d 字节 (%.2f MiB)",bytes,bytes/1048576
            printf " | 均速 %.2f MiB/s | %ds%s",rate,seconds,(done ? " | 下载完成" : "")
        }
    ' "$4")
    printf '%s' "$_dp_line" >&2
    mp_log_event "$_dp_line"
}

# URL/output/Core/fallback/label/timeout/min-size. Only log sanitized commands.
mp_http_download() (
    _hd_url=$1; _hd_dst=$2; _hd_core=$3; _hd_proxy=$4
    _hd_label=${5:-文件}; _hd_timeout=${6:-300}; _hd_min=${7:-0}
    _hd_meta=$(mktemp -d) || exit 1
    _hd_pid=
    trap '[ -z "$_hd_pid" ] || { kill "$_hd_pid" 2>/dev/null; wait "$_hd_pid" 2>/dev/null; }; rm -rf -- "$_hd_meta"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    mp_init_log "${MP_LOG_FILE:-${INST_ENTRY_DIR:-${MP_INST_DIR:-.}/sh}/myrule.inst.log}" || exit 1
    mp_download_message "下载：$_hd_label"
    _hd_round=0
    while :; do
        _hd_transient=0
        for _hd_kind in core fallback direct; do
            case "$_hd_kind" in
                core) [ -n "$_hd_core" ] || continue; _hd_channel=$_hd_core; _hd_name='Core 本机代理' ;;
                fallback) [ -n "$_hd_proxy" ] && [ "$_hd_proxy" != "$_hd_core" ] || continue
                    _hd_channel=$_hd_proxy; _hd_name='外部后备代理' ;;
                direct) _hd_channel=; _hd_name=直连 ;;
            esac
            mp_download_message "  尝试：$_hd_name"
            _hd_noproxy=; [ -n "$_hd_channel" ] || _hd_noproxy='*'
            set -- --disable --fail -L --connect-timeout 10 --max-time "$_hd_timeout" \
                --speed-limit 1 --speed-time 30 --proxy "$_hd_channel" --noproxy "$_hd_noproxy" \
                --write-out '%{http_code}' --dump-header "$_hd_meta/headers" "$_hd_url" -o "$_hd_dst" --silent
            : > "$_hd_dst" || exit 1
            : > "$_hd_meta/headers"
            _hd_start=$(date +%s); _hd_last=-5; _hd_previous=0
            mp_log_command curl "$@" || exit 1
            curl "$@" > "$_hd_meta/http" 2>/dev/null &
            _hd_pid=$!
            while kill -0 "$_hd_pid" 2>/dev/null; do
                _hd_bytes=$(wc -c < "$_hd_dst"); _hd_elapsed=$(($(date +%s) - _hd_start))
                if { [ -t 2 ] && [ "$_hd_elapsed" -gt "$_hd_last" ]; } || [ "$((_hd_elapsed - _hd_last))" -ge 5 ] \
                    || { [ "$_hd_previous" -eq 0 ] && [ "$_hd_bytes" -gt 0 ]; }; then
                    [ ! -t 2 ] || printf '\r\033[K' >&2
                    mp_download_progress "$_hd_bytes" "$_hd_elapsed" 0 "$_hd_meta/headers"
                    [ -t 2 ] || printf '\n' >&2
                    _hd_last=$_hd_elapsed; _hd_previous=$_hd_bytes
                fi
                sleep 0.2
            done
            _hd_rc=0; wait "$_hd_pid" || _hd_rc=$?; _hd_pid=
            _hd_bytes=$(wc -c < "$_hd_dst"); _hd_elapsed=$(($(date +%s) - _hd_start))
            _hd_http=$(cat "$_hd_meta/http")
            case "$_hd_http" in [0-9][0-9][0-9]) ;; *) _hd_http=000 ;; esac
            if [ "$_hd_rc" = 0 ] && [ "$_hd_bytes" -gt "$_hd_min" ]; then
                mp_log_event "下载成功：$_hd_label；curl 0；HTTP $_hd_http；$_hd_bytes 字节；${_hd_elapsed}s"
                [ ! -t 2 ] || printf '\r\033[K' >&2
                mp_download_progress "$_hd_bytes" "$_hd_elapsed" 1 "$_hd_meta/headers"
                printf '\n' >&2
                exit 0
            fi
            [ ! -t 2 ] || printf '\n' >&2
            _hd_retry=0
            case "$_hd_rc" in
                0) _hd_reason='响应为空或过小' ;;
                5|6) _hd_reason='DNS 解析失败'; _hd_retry=1 ;;
                7) _hd_reason='连接失败'; _hd_retry=1 ;;
                18|52|55|56) _hd_reason='传输中断'; _hd_retry=1 ;;
                28) _hd_reason='请求超时或连续 30 秒无数据'; _hd_retry=1 ;;
                35) _hd_reason='TLS 握手失败'; _hd_retry=1 ;;
                60) _hd_reason='TLS 证书校验失败' ;;
                22) _hd_reason='HTTP 请求失败'
                    case "$_hd_http" in 408|429|500|502|503|504) _hd_retry=1 ;; esac ;;
                23|26) _hd_reason='本地文件读写失败' ;;
                *) _hd_reason='下载失败' ;;
            esac
            mp_download_message "  $_hd_name：$_hd_reason（curl $_hd_rc，HTTP $_hd_http）"
            # Retry only if the final direct attempt was transient; a final 404/403 is conclusive.
            _hd_transient=$_hd_retry
            case "$_hd_rc" in 23|26) exit 1 ;; esac
        done
        [ "$_hd_transient" = 1 ] && [ "$_hd_round" -lt 2 ] || exit 1
        _hd_round=$((_hd_round + 1))
        mp_download_message "  临时错误，自动重试 $_hd_round/2"
        sleep 1
    done
)
# END shared HTTP transport

# Only the target requires Linux TUN; launchers (including macOS) do not.
mp_require_tun() {
    [ -c /dev/net/tun ] && ( : <>/dev/net/tun ) 2>/dev/null && return 0
    printf '%s\n' '目标机无法访问 /dev/net/tun；请加载 tun 模块，容器须由宿主机开放并挂载 TUN 设备' >&2
    return 1
}
