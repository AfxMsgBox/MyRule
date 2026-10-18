#!/bin/sh
# cron 每天调用；按连续日而非每月日期判断是否到期。
# 函数整体解析后执行，避免更新脚本时替换本文件影响当前流程。
scheduled_main() {
    case "${1:-}" in
        scripts) scheduled_script=update-scripts.sh ;;
        configs) scheduled_script=update-all-configs-restart-services.sh ;;
        *) return 1 ;;
    esac
    scheduled_kind=$1
    case "${2:-}" in ''|*[!0-9]*|0*) return 1 ;; esac
    [ "$2" -le 365 ] 2>/dev/null || return 1
    scheduled_days=$2
    scheduled_dir=$(dirname "$(readlink -f "$0")") || return 1
    scheduled_state="$scheduled_dir/.schedule"
    mkdir -p "$scheduled_state" || return 1
    # 两类自动更新共用锁，避免一个更新脚本时另一个正在读取它。
    exec 9>"$scheduled_state/lock" || return 1
    flock -n 9 || return 0
    scheduled_now=$(date +%s) || return 1
    scheduled_today=$((scheduled_now / 86400))
    scheduled_last_file="$scheduled_state/$scheduled_kind.last"
    scheduled_last=
    if [ -f "$scheduled_last_file" ]; then
        IFS= read -r scheduled_last < "$scheduled_last_file" || return 1
        case "$scheduled_last" in ''|*[!0-9]*|0[0-9]*) return 1 ;; esac
        [ "${#scheduled_last}" -le 8 ] || return 1
        [ "$((scheduled_today - scheduled_last))" -ge "$scheduled_days" ] || return 0
    fi
    # cron 不询问下载重试；用户手动更新入口的行为不变。
    _MP_NONINTERACTIVE=1
    MP_INST_DIR=$(dirname "$scheduled_dir")
    export _MP_NONINTERACTIVE MP_INST_DIR
    if sh "$scheduled_dir/$scheduled_script"; then
        scheduled_tmp=$(mktemp "$scheduled_last_file.XXXXXX") || return 1
        if ! printf '%s\n' "$scheduled_today" > "$scheduled_tmp" ||
           ! mv "$scheduled_tmp" "$scheduled_last_file"; then
            rm -f "$scheduled_tmp"; return 1
        fi
        logger -t MyProxy "定时更新 $scheduled_kind 成功，下次间隔 $scheduled_days 天"
    else
        logger -t MyProxy "定时更新 $scheduled_kind 失败，下次定时检查重试"
        return 1
    fi
}

scheduled_main "$@"
