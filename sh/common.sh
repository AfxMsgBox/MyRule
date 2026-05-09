#!/bin/sh
# 公共函数库。caller 在 source 前设 url_self="$MP_URL_..." 表达自更新目标。
# 命名约定：MP_* 全局；小写本地。

# 当前脚本路径（自更新覆写自身用）
path_self=$(readlink -f "$0" 2>/dev/null || echo "$0")

# 加载 env.conf：先 caller 目录，回退 /etc/proxy/sh
if [ -f "$(dirname "$path_self")/env.conf" ]; then
    . "$(dirname "$path_self")/env.conf"
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

# download_file <url> <dst> [use_proxy] [min_size=8]
# use_proxy 缺省取 $MP_USE_PROXY；显式传 0/1 可覆盖（如 inst.sh 的 bootstrap 阶段强制直连）。
# 走代理失败自动回退直连；--fail 让 4xx/5xx 不被当成功；mktemp + mv 原子替换。
download_file() {
    url="$1"; dst="$2"; use_proxy="${3:-$MP_USE_PROXY}"; min_size="${4:-8}"
    case "$use_proxy" in 1|true|yes) proxy_arg="--proxy $MP_PROXY_HTTP" ;; *) proxy_arg="" ;; esac
    tmp=$(mktemp)
    curl --silent --show-error --fail --connect-timeout 10 --max-time 60 \
         --retry 2 --retry-delay 1 $proxy_arg "$url" -o "$tmp" >/dev/null 2>&1
    rc=$?
    if [ "$rc" -ne 0 ] && [ -n "$proxy_arg" ]; then
        echo_log "下载经代理失败，回退直连：$url"
        curl --silent --show-error --fail --connect-timeout 10 --max-time 60 \
             --retry 2 --retry-delay 1 "$url" -o "$tmp" >/dev/null 2>&1
        rc=$?
    fi
    if [ "$rc" -ne 0 ] || [ "$(get_file_size "$tmp")" -le "$min_size" ]; then
        rm -f "$tmp"; return 1
    fi
    mv "$tmp" "$dst"
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

# 自更新：MP_AUTOUPDATE=true/1/yes 触发；
#   - env.conf / common.sh：进程树只下一次，用 export _DEPS_UPDATED=1 标记，
#     子进程通过环境继承自动跳过
#   - 当前脚本（url_self）：每个 script 各自下一次，下完后 exec 重启时附 --skip-self-update
#     防自身陷入无限重入；该 flag 不会传给子脚本，所以子脚本能正常更新自己
# 命令行 --autoupdate=true|false 覆盖 env 中 MP_AUTOUPDATE 的值
_skip_self=0
for arg in "$@"; do
    case "$arg" in
        --autoupdate=*)     MP_AUTOUPDATE="${arg#*=}" ;;
        --autoupdate)       MP_AUTOUPDATE=true ;;
        --skip-self-update) _skip_self=1 ;;
    esac
done
case "$0" in *common.sh) url_self="${url_self:-$MP_URL_COMMON_SH}" ;; esac

case "$MP_AUTOUPDATE" in
    1|true|yes)
        if [ -n "$url_self" ]; then
            # env.conf + common.sh 全进程树只下一次
            if [ "$_DEPS_UPDATED" != "1" ]; then
                download_file "$MP_URL_ENV_CONF"  "$dir_self/env.conf"  >/dev/null 2>&1
                download_file "$MP_URL_COMMON_SH" "$dir_self/common.sh" >/dev/null 2>&1
                export _DEPS_UPDATED=1
            fi
            # 当前脚本只下一次（exec 重启后 _skip_self=1 跳过这段）
            if [ "$_skip_self" = "0" ]; then
                if download_file "$url_self" "$path_self"; then
                    echo_log "self-update OK: $path_self"
                    exec sh "$path_self" "$@" --skip-self-update
                fi
                echo_log "self-update FAILED: $path_self"
            fi
        fi
        ;;
esac
