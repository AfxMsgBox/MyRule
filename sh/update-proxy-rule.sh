#!/bin/sh
url_self="$MP_URL_UPDATE_PROXY_RULE_SH"
. "$(dirname "$(readlink -f "$0")")/common.sh"

config_yaml="$MP_CORE_DIR/config.yaml"
[ -f "$config_yaml" ] || { echo_log "未找到 $config_yaml，跳过"; exit 0; }

# put_provider <kind> <name>，kind=proxies|rules；失败返回 1
put_provider() {
    code=$(curl --silent --show-error --max-time 30 -o /dev/null -w '%{http_code}' \
                -X PUT "$MP_CORE_API/providers/$1/$2" 2>&1)
    if [ "$code" = "204" ] || [ "$code" = "200" ]; then
        echo_log "刷新 $1/$2 OK"
    else
        echo_log "刷新 $1/$2 失败（HTTP $code）"
        return 1
    fi
}

rc=0
# pipe | while 在子 shell 里跑，rc 改了不会传回父 shell；改用临时文件 + 重定向
tmpf=$(mktemp)

echo_log "刷新代理订阅..."
_yaml_extract_keys "$config_yaml" "proxy-providers" > "$tmpf"
while IFS= read -r name; do
    [ -z "$name" ] && continue
    put_provider proxies "$name" || rc=$((rc+1))
    sleep 2
done < "$tmpf"

echo_log "刷新规则集..."
_yaml_extract_keys "$config_yaml" "rule-providers" > "$tmpf"
while IFS= read -r name; do
    [ -z "$name" ] && continue
    put_provider rules "$name" || rc=$((rc+1))
    sleep 2
done < "$tmpf"

rm -f "$tmpf"
exit "$rc"
