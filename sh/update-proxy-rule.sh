#!/bin/sh
# 触发 mihomo 增量刷新所有 proxy-providers 与 rule-providers（PUT /providers/...）
. "$(dirname "$(readlink -f "$0" 2>/dev/null || printf '%s\n' "$0")")/common.sh"

config_yaml="$MP_CORE_DIR/config.yaml"
[ -f "$config_yaml" ] || { echo_log "未找到 $config_yaml，跳过"; exit 0; }
core_api=$(mp_core_api_url "$config_yaml") \
    || { echo_log "无法从 Core 配置读取有效的 external-controller"; exit 1; }
core_secret=$(mp_core_value "" secret "$config_yaml" 2>/dev/null || :)

# put_provider <kind> <name>：HTTP 204/200 视为成功
put_provider() {
    _pp_provider="$1/$2"
    echo_log "开始刷新 $_pp_provider（由 Core 下载，等待 API 结果）"
    set -- --disable --silent --max-time 30 -o /dev/null -w '%{http_code}' --proxy '' --noproxy '*'
    [ -z "$core_secret" ] || set -- "$@" -H "Authorization: Bearer $core_secret"
    set -- "$@" -X PUT "$core_api/providers/$_pp_provider"
    mp_log_command curl "$@"
    _pp_rc=0; code=$(curl "$@" 2>/dev/null) || _pp_rc=$?
    case "$code" in [0-9][0-9][0-9]) ;; *) code=000 ;; esac
    case "$_pp_rc:$code" in
        0:200|0:204) echo_log "刷新 $_pp_provider OK" ;;
        *) echo_log "刷新 $_pp_provider 失败（curl $_pp_rc，HTTP $code）"; return 1 ;;
    esac
}

# 遍历 config.yaml 顶层 map 下所有 key，逐个 put_provider；返回失败计数
# pipe|while 会跑在子 shell 里丢失变量，故走临时文件
refresh_block() {
    _kind=$1; _top=$2; _fail=0
    _yaml_extract_keys "$config_yaml" "$_top" > "$tmpf"
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        put_provider "$_kind" "$name" || _fail=$((_fail+1))
        sleep 2
    done < "$tmpf"
    return "$_fail"
}

tmpf=$(mktemp); rc=0
echo_log "刷新代理订阅..."
refresh_block proxies "proxy-providers" || rc=$((rc + $?))
echo_log "刷新规则集..."
refresh_block rules   "rule-providers"  || rc=$((rc + $?))
rm -f "$tmpf"
exit "$rc"
