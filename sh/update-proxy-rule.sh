#!/bin/sh
# 不重启进程，通过代理内核 RESTful 控制器刷新订阅与规则集。
# provider 名称从 core/config.yaml 自动发现，避免与硬编码漂移。

URL_SCRIPT="${REPO_RAW_URL:-https://raw.githubusercontent.com/AfxMsgBox/MyRule/main}/sh/update-proxy-rule.sh"
DIR_SCRIPT=$(dirname "$(readlink -f "$0")")

# shellcheck disable=SC1091
. "$DIR_SCRIPT/common.sh"

CORE_API="${CORE_API:-http://127.0.0.1:3721}"
CORE_DIR="${CORE_DIR:-$DIR_SCRIPT/../core}"
CONFIG_YAML="$CORE_DIR/config.yaml"

if [ ! -f "$CONFIG_YAML" ]; then
    echo_log "未找到 $CONFIG_YAML，跳过"
    exit 0
fi

# put_provider <kind> <name>，kind=proxies|rules
_put_provider() {
    _kind="$1"; _name="$2"
    _resp=$(curl --silent --show-error --max-time 30 -o /dev/null -w '%{http_code}' \
                 -X PUT "$CORE_API/providers/$_kind/$_name" 2>&1)
    if [ "$_resp" = "204" ] || [ "$_resp" = "200" ]; then
        echo_log "刷新 $_kind/$_name OK"
    else
        echo_log "刷新 $_kind/$_name 失败（HTTP $_resp）"
    fi
}

echo_log "刷新代理订阅..."
_proxy_providers=$(_yaml_extract_keys "$CONFIG_YAML" "proxy-providers")
if [ -z "$_proxy_providers" ]; then
    echo_log "未在 $CONFIG_YAML 中发现 proxy-providers"
else
    echo "$_proxy_providers" | while IFS= read -r name; do
        [ -z "$name" ] && continue
        _put_provider proxies "$name"
        sleep 2
    done
fi

echo_log "刷新规则集..."
_rule_providers=$(_yaml_extract_keys "$CONFIG_YAML" "rule-providers")
if [ -z "$_rule_providers" ]; then
    echo_log "未在 $CONFIG_YAML 中发现 rule-providers"
else
    echo "$_rule_providers" | while IFS= read -r name; do
        [ -z "$name" ] && continue
        _put_provider rules "$name"
        sleep 2
    done
fi
