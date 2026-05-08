#!/bin/sh
# 公共函数库：被各 update-*.sh 通过 `source common.sh` 引入。
# 提供：日志、下载、占位符替换、yaml 提取、脚本自更新。
#
# 调用方约定：在 source 本文件之前可设 url_self 指向自己的 raw URL，
# 自更新会用它把当前脚本覆盖为最新版后 exec 重启。
#
# 命名约定：
#   MP_*  来自 env.conf 的全局变量（必须）
#   小写  本文件 / 调用方的局部变量

# 当前脚本绝对路径（自更新时用来覆写自己）；wget|sh 管道场景下 $0 可能是 "sh"
path_self=$(readlink -f "$0" 2>/dev/null || echo "$0")
# 当前脚本所在目录
dir_self=$(dirname "$path_self")

# env.conf 查找：先 dir_self（开发 / 自定义路径）；再 /etc/proxy/sh（约定部署位置，
# 用于 inst.sh 通过 wget|sh 启动时 $0 不指向真实路径的场景）
env_dir=""
for d in "$dir_self" /etc/proxy/sh; do
    if [ -f "$d/env.conf" ]; then
        env_dir="$d"
        break
    fi
done
[ -n "$env_dir" ] || { echo "缺少 env.conf（试过 $dir_self 与 /etc/proxy/sh）" >&2; exit 1; }
# 加载全局变量
# shellcheck disable=SC1091
. "$env_dir/env.conf"
# 本地覆盖（可选）
# shellcheck disable=SC1091
[ -f "$env_dir/env.local.conf" ] && . "$env_dir/env.local.conf"

# ----------------------------------------------------------------------
# 日志：同时打到终端和系统 log（logread / journalctl 都能查到）
# ----------------------------------------------------------------------
echo_log() {
    # 输出到 stdout 便于实时观察
    echo "$1"
    # 写入系统日志，统一 tag 方便过滤
    logger -t "$MP_LOG_TAG" -- "$1"
}

# ----------------------------------------------------------------------
# 取文件字节数；不存在时返回 0
# ----------------------------------------------------------------------
get_file_size() {
    [ -f "$1" ] && wc -c < "$1" | tr -d ' \n' || echo 0
}

# ----------------------------------------------------------------------
# 下载（带代理 / 直连回退 / 大小校验 / 原子替换）
#   download_file <url> <dst> [use_proxy=1] [min_size=8]
#   use_proxy: 1/true/yes 才走 MP_PROXY_HTTP；其它值（含 0/no/空）走直连。
#   走代理失败时自动直连重试一次。
# ----------------------------------------------------------------------
download_file() {
    # 必填：源 URL
    url="${1:?url required}"
    # 必填：目标路径
    dst="${2:?dst required}"
    # 可选：是否走代理，默认 1
    use_proxy="${3:-1}"
    # 可选：成功最小字节数，默认 8
    min_size="${4:-8}"

    # 根据 use_proxy 决定 curl 是否带 --proxy
    case "$use_proxy" in
        1|true|TRUE|yes|YES|on|ON) proxy_arg="--proxy $MP_PROXY_HTTP" ;;
        *)                          proxy_arg="" ;;
    esac

    # 临时文件用 mktemp，避免并发跑互踩
    tmp=$(mktemp 2>/dev/null) || tmp="/tmp/.dl.$$"

    # 第一次尝试：按 use_proxy 设置走代理或直连
    # --fail 让 4xx/5xx 也当下载失败，避免把 404 HTML 当成正常文件覆盖目标
    # shellcheck disable=SC2086
    curl --silent --show-error --fail --connect-timeout 10 --max-time 60 \
         --retry 2 --retry-delay 1 \
         $proxy_arg "$url" -o "$tmp" >/dev/null 2>&1
    rc=$?

    # 走代理失败时自动降级直连重试一次
    if [ "$rc" -ne 0 ] && [ -n "$proxy_arg" ]; then
        echo_log "下载经代理失败，回退直连：$url"
        curl --silent --show-error --fail --connect-timeout 10 --max-time 60 \
             --retry 2 --retry-delay 1 \
             "$url" -o "$tmp" >/dev/null 2>&1
        rc=$?
    fi

    # 任一次成功且文件够大才接受；否则清理临时文件返回 1
    if [ "$rc" -ne 0 ] || [ "$(get_file_size "$tmp")" -le "$min_size" ]; then
        rm -f "$tmp"
        return 1
    fi

    # 原子替换：mv 在同一个 fs 上是 rename(2)，不会出现半截文件
    mv "$tmp" "$dst"
}

# ----------------------------------------------------------------------
# 占位符替换：把 target 中的 {KEY} 用 kv 文件里 KEY=VALUE 的 VALUE 换掉。
# 严格按"第一个 ="切分，所以 VALUE 中可以含 =。
# ----------------------------------------------------------------------
replace_strings_from_config() {
    # kv 配置文件
    config_file="$1"
    # 待替换的目标文件（就地修改）
    target_file="$2"
    # 任一文件不存在则直接报错返回
    [ -f "$config_file" ] && [ -f "$target_file" ] || return 1

    # 用 awk 加载 kv 后逐行替换；写到 .tmp 再 mv 回去做原子替换
    awk '
    NR == FNR {
        idx = index($0, "=")
        if (idx > 0) {
            k = substr($0, 1, idx-1)
            v = substr($0, idx+1)
            map["{" k "}"] = v
        }
        next
    }
    {
        line = $0
        for (k in map) {
            out = ""; rem = line
            while ((idx = index(rem, k)) > 0) {
                out = out substr(rem, 1, idx-1) map[k]
                rem = substr(rem, idx+length(k))
            }
            line = out rem
        }
        print line
    }
    ' "$config_file" "$target_file" > "${target_file}.tmp" && \
        mv "${target_file}.tmp" "$target_file"
}

# ----------------------------------------------------------------------
# 从缩进式 yaml 取顶层 map 下的子 key 列表（够覆盖 mihomo 配置）。
#   _yaml_extract_keys <file> <top-key>
# ----------------------------------------------------------------------
_yaml_extract_keys() {
    # 待解析的 yaml 文件
    file="$1"
    # 顶层 key 名
    top="$2"
    # 文件不存在则返回
    [ -f "$file" ] || return 1

    awk -v top="$top" '
    BEGIN { in_blk = 0; child_indent = -1 }
    $0 ~ "^" top ":[[:space:]]*$" { in_blk = 1; next }
    in_blk {
        if ($0 ~ /^[[:space:]]*$/) next
        if ($0 ~ /^[[:space:]]*#/) next
        match($0, /^[[:space:]]*/); indent = RLENGTH
        if (indent == 0) { in_blk = 0; next }
        if (child_indent < 0) child_indent = indent
        if (indent != child_indent) next
        line = $0
        sub(/^[[:space:]]+/, "", line)
        if (match(line, /^[A-Za-z0-9_.-]+:/)) {
            print substr(line, 1, RLENGTH-1)
        }
    }
    ' "$file"
}

# ----------------------------------------------------------------------
# 自更新决策：
#   1) 命令行含 --noupdate      → 跳过
#   2) MP_NOUPDATE=true/1/yes  → 跳过
#   3) caller 未设 url_self    → 跳过（如 inst.sh 走 wget|sh，$0 不可靠，
#                                    强行更新会写到 /usr/bin/sh 等危险位置）
#   4) common.sh 被直接执行     → 自动用 MP_URL_COMMON_SH 更新 common.sh 自己
#   5) 其它情况                 → 用 url_self 更新 caller 后 exec 重启
# ----------------------------------------------------------------------
case " $* " in
    *" --noupdate "*) MP_NOUPDATE=true ;;
esac

# 直接执行 common.sh 时（如 update-all-configs.sh 用 sh common.sh 触发自身刷新），
# 自动把 url_self 指向 common.sh 的 raw URL
case "$0" in
    *common.sh) url_self="${url_self:-$MP_URL_COMMON_SH}" ;;
esac

case "$MP_NOUPDATE" in
    1|true|TRUE|yes|YES|on|ON) ;;
    *)
        if [ -z "$url_self" ]; then
            : # caller 没声明更新目标，安静跳过
        elif download_file "$url_self" "$path_self"; then
            echo_log "self-update OK: $path_self"
            # 透传原参数 + 加 --noupdate 防止再次重入
            exec sh "$path_self" "$@" --noupdate
        else
            echo_log "self-update FAILED: $path_self"
        fi
        ;;
esac
