#!/bin/sh
URL_SCRIPT="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/update-proxy-rule.sh"

DIR_SCRIPT="$(cd "$(dirname "$0")" && pwd)"
source $DIR_SCRIPT"/common.sh"
#----------------------------------------------------
SED_EXPR=""

replace_strings_from_config() {
    CONFIG_FILE="$1"

    # 从配置文件中读取所有的键值对并构建 sed 表达式
    while IFS='=' read -r key value; do
        # 跳过空行或无效行
        if [ -z "$key" ] || [ -z "$value" ]; then
            continue
        fi

        # 转义特殊字符
        ESCAPED_KEY=$(printf '%s\n' "$key" | sed -e 's/[][\/.^$*]/\\&/g')
        ESCAPED_VALUE=$(printf '%s\n' "$value" | sed -e 's/[&\\/]/\\&/g')

        # 构建 sed 表达式
        SED_EXPR="${SED_EXPR}s|{${ESCAPED_KEY}}|${ESCAPED_VALUE}|g;"
    done < "$CONFIG_FILE"
}

#----------------------------------------------------
echo_log "update clash proxy & rules."

echo_log "update TaiWan proxy..."
curl -X PUT  http://127.0.0.1:3721/providers/proxies/TaiWan
sleep 2s

echo_log "update HongKong proxy..."
curl -X PUT  http://127.0.0.1:3721/providers/proxies/HongKong
sleep 2s

echo_log "update gpt rules..."
curl -X PUT  http://127.0.0.1:3721/providers/rules/rule_gpt
