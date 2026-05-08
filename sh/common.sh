#!/bin/sh
# 公共函数库：被各 update-*.sh 通过 `source common.sh` 引入。
# 提供：日志、下载、占位符替换、并发锁、yaml 提取、脚本自更新。

PATH_SCRIPT=$(readlink -f "$0")
DIR_SCRIPT=$(dirname "$PATH_SCRIPT")

# 加载共享环境（PROXY_HTTP / CORE_* / REPO_RAW_URL / LOG_TAG ...）
[ -f "$DIR_SCRIPT/env.conf" ] && . "$DIR_SCRIPT/env.conf"

LOG_TAG="${LOG_TAG:-MyProxy}"
PROXY_HTTP="${PROXY_HTTP:-http://127.0.0.1:7890}"
REPO_RAW_URL="${REPO_RAW_URL:-https://raw.githubusercontent.com/AfxMsgBox/MyRule/main}"
_URL_COMMON_SH="${_URL_COMMON_SH:-$REPO_RAW_URL/sh/common.sh}"

# ----------------------------------------------------------------------
# 基础工具
# ----------------------------------------------------------------------

get_file_size() {
    [ -f "$1" ] && wc -c < "$1" | tr -d ' \n' || echo 0
}

echo_log() {
    [ $# -eq 0 ] && return
    echo "$1"
    logger -t "$LOG_TAG" -- "$1"
}

# _run_step <label> <cmd...> —— 包一段子任务，统一日志与 exit code 汇总。
# 失败不会让外层退出，便于"全部跑完再决定要不要重启服务"。返回子命令 exit。
_run_step() {
    label="$1"; shift
    echo_log ">>> $label"
    "$@"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        echo_log "<<< $label OK"
    else
        echo_log "<<< $label FAILED (rc=$rc)"
    fi
    return $rc
}

# _acquire_lock <path> —— 防止多实例并发跑（cron + 手动）。flock 不存在时降级为 noop。
_acquire_lock() {
    lock="${1:-/var/lock/myrule.lock}"
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$lock" 2>/dev/null || return 0
        flock -n 9 || { echo_log "another instance is running, exit."; exit 0; }
    fi
}

# ----------------------------------------------------------------------
# 下载（带代理 / 直连回退 / 临时文件 / 大小校验）
# ----------------------------------------------------------------------

# download_file <url> <dst> [use_proxy=1] [min_size=8]
# use_proxy: 1/true/yes 才启用本地 7890 代理；其它值（含 0/no/false/空）走直连。
# 默认先按 use_proxy 设置尝试一次；若使用代理失败，自动降级到直连重试一次。
download_file() {
    url="${1:?url required}"
    dst="${2:?dst required}"
    use_proxy="${3:-1}"
    min_size="${4:-8}"

    case "$use_proxy" in
        1|true|TRUE|yes|YES|on|ON) proxy_arg="--proxy $PROXY_HTTP" ;;
        *)                          proxy_arg="" ;;
    esac

    tmp=$(mktemp 2>/dev/null) || tmp="/tmp/.dl.$$"
    trap 'rm -f "$tmp"' EXIT INT TERM

    _try() {
        # shellcheck disable=SC2086
        curl --silent --show-error --connect-timeout 10 --max-time 60 \
             --retry 2 --retry-delay 1 \
             $1 "$url" -o "$tmp" >/dev/null 2>&1
    }

    _try "$proxy_arg"
    rc=$?
    if [ "$rc" -ne 0 ] && [ -n "$proxy_arg" ]; then
        echo_log "download via proxy failed, retry direct: $url"
        _try ""
        rc=$?
    fi

    if [ "$rc" -ne 0 ]; then
        rm -f "$tmp"
        return 1
    fi

    size=$(get_file_size "$tmp")
    if [ -z "$size" ] || [ "$size" -le "$min_size" ]; then
        rm -f "$tmp"
        return 1
    fi

    mv "$tmp" "$dst"
    trap - EXIT INT TERM
    return 0
}

# ----------------------------------------------------------------------
# 占位符替换：把 {KEY} 用 kv_file 中 KEY=VALUE 的 VALUE 替换。
# 严格按第一个 "=" 切分，避免 VALUE 内含 = 时丢字段。
# ----------------------------------------------------------------------
replace_strings_from_config() {
    config_file="$1"
    target_file="$2"
    [ -f "$config_file" ] && [ -f "$target_file" ] || return 1

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
# 从 yaml 提取顶层 map 下的子 key（缩进式 yaml，足够覆盖 mihomo 配置）。
# 用法：_yaml_extract_keys <yaml> <top-key>
# 例：_yaml_extract_keys core/config.yaml proxy-providers -> 每行一个 provider 名
# ----------------------------------------------------------------------
_yaml_extract_keys() {
    file="$1"; top="$2"
    [ -f "$file" ] || return 1
    awk -v top="$top" '
    BEGIN { in_blk = 0; child_indent = -1 }
    # 进入 top: 块
    $0 ~ "^" top ":[[:space:]]*$" { in_blk = 1; next }
    in_blk {
        # 空行不结束块（mihomo yaml 经常有空行分隔）
        if ($0 ~ /^[[:space:]]*$/) next
        # 注释行跳过
        if ($0 ~ /^[[:space:]]*#/) next
        # 计算前导空白长度
        match($0, /^[[:space:]]*/); indent = RLENGTH
        # 顶级行（无缩进）说明块结束
        if (indent == 0) { in_blk = 0; next }
        # 第一个孩子定义其缩进；只在该缩进上取 key
        if (child_indent < 0) child_indent = indent
        if (indent != child_indent) next
        # 解析 "name:" —— 必须以冒号结尾或冒号后空格
        line = $0
        sub(/^[[:space:]]+/, "", line)
        if (match(line, /^[A-Za-z0-9_.-]+:/)) {
            key = substr(line, 1, RLENGTH-1)
            print key
        }
    }
    ' "$file"
}

# ----------------------------------------------------------------------
# 脚本自更新：调用方在 source common.sh 之前设置 URL_SCRIPT 指向自己的 raw URL。
# 启动参数含 --noupdate 时跳过；否则用 download_file 替换自身后 exec 重启，并透传原参数。
# 当 common.sh 被直接执行（sh common.sh）时，URL_SCRIPT 缺省回退到 _URL_COMMON_SH。
# ----------------------------------------------------------------------
_URL_SCRIPT_EFFECTIVE="${URL_SCRIPT:-$_URL_COMMON_SH}"
_NEED_UPDATE=1
for _a in "$@"; do
    [ "$_a" = "--noupdate" ] && _NEED_UPDATE=0
done

if [ "$_NEED_UPDATE" = "1" ] && [ -n "$_URL_SCRIPT_EFFECTIVE" ]; then
    if download_file "$_URL_SCRIPT_EFFECTIVE" "$PATH_SCRIPT"; then
        echo_log "self-update OK: $PATH_SCRIPT"
        exec sh "$PATH_SCRIPT" "$@" --noupdate
    else
        echo_log "self-update FAILED: $PATH_SCRIPT"
    fi
fi
unset _NEED_UPDATE _URL_SCRIPT_EFFECTIVE _a
