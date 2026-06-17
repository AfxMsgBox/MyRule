#!/bin/sh
# 触发 mihomo 增量刷新所有 proxy-providers 与 rule-providers（PUT /providers/...）
. "$(dirname "$(readlink -f "$0")")/common.sh"

config_yaml="$MP_CORE_DIR/config.yaml"
[ -f "$config_yaml" ] || { echo_log "未找到 $config_yaml，跳过"; exit 0; }

# put_provider <kind> <name>：HTTP 204/200 视为成功
put_provider() {
    code=$(curl --silent --show-error --max-time 30 -o /dev/null -w '%{http_code}' \
                -X PUT "$MP_CORE_API/providers/$1/$2" 2>&1)
    case "$code" in
        200|204) echo_log "刷新 $1/$2 OK" ;;
        *)       echo_log "刷新 $1/$2 失败（HTTP $code）"; return 1 ;;
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
