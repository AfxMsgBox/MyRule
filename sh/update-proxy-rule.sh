#!/bin/sh
# 不重启内核，通过 RESTful 控制器 PUT 刷新订阅与规则集。
# provider 名称从 core/config.yaml 自动发现，不再硬编码。

# 自更新用：本脚本的 raw URL（来自 env 全局）
url_self="$MP_URL_UPDATE_PROXY_RULE_SH"
# 本脚本所在目录
dir_self=$(dirname "$(readlink -f "$0")")
# 加载公共函数与 env
# shellcheck disable=SC1091
. "$dir_self/common.sh"

# 内核主配置
config_yaml="$MP_CORE_DIR/config.yaml"

# 配置不存在则跳过（首次部署还没生成 yaml）
[ -f "$config_yaml" ] || { echo_log "未找到 $config_yaml，跳过"; exit 0; }

# put_provider <kind> <name>，kind=proxies|rules
put_provider() {
    # 30 秒超时，只关心 HTTP 状态码
    code=$(curl --silent --show-error --max-time 30 -o /dev/null -w '%{http_code}' \
                -X PUT "$MP_CORE_API/providers/$1/$2" 2>&1)
    # 204 / 200 视为成功
    [ "$code" = "204" ] || [ "$code" = "200" ] \
        && echo_log "刷新 $1/$2 OK" \
        || echo_log "刷新 $1/$2 失败（HTTP $code）"
}

echo_log "刷新代理订阅..."
# 从 yaml 自动发现 proxy-providers
_yaml_extract_keys "$config_yaml" "proxy-providers" | while IFS= read -r name; do
    # 跳过空行
    [ -z "$name" ] && continue
    put_provider proxies "$name"
    # 节流：避免对源站短时间高并发
    sleep 2
done

echo_log "刷新规则集..."
# 同样自动发现 rule-providers
_yaml_extract_keys "$config_yaml" "rule-providers" | while IFS= read -r name; do
    [ -z "$name" ] && continue
    put_provider rules "$name"
    sleep 2
done
