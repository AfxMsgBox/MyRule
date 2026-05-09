#!/bin/sh
url_self="$MP_URL_UPDATE_PROXY_RULE_SH"
. "$(dirname "$(readlink -f "$0")")/common.sh"

config_yaml="$MP_CORE_DIR/config.yaml"
[ -f "$config_yaml" ] || { echo_log "未找到 $config_yaml，跳过"; exit 0; }

# put_provider <kind> <name>，kind=proxies|rules
put_provider() {
    code=$(curl --silent --show-error --max-time 30 -o /dev/null -w '%{http_code}' \
                -X PUT "$MP_CORE_API/providers/$1/$2" 2>&1)
    [ "$code" = "204" ] || [ "$code" = "200" ] \
        && echo_log "刷新 $1/$2 OK" \
        || echo_log "刷新 $1/$2 失败（HTTP $code）"
}

echo_log "刷新代理订阅..."
_yaml_extract_keys "$config_yaml" "proxy-providers" | while IFS= read -r name; do
    [ -z "$name" ] && continue
    put_provider proxies "$name"
    sleep 2
done

echo_log "刷新规则集..."
_yaml_extract_keys "$config_yaml" "rule-providers" | while IFS= read -r name; do
    [ -z "$name" ] && continue
    put_provider rules "$name"
    sleep 2
done
