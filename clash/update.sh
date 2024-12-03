#!/bin/sh
URL_SCRIPT="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/clash/update.sh"
URL_CONFIG="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/clash/config.yaml"
DIR_SCRIPT="$(cd "$(dirname "$0")" && pwd)"
_PROXY="http://127.0.0.1:7890"

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
get_file_size() { [ -f "$1" ] && ls -l "$1" | awk '{print $5}' || echo 0; }
echo_log() { [ $# -eq 1 ] && set -- "$1" "$1"; echo "$1" && logger "$2"; }

download_file() {
        #下载URL 目标文件名  1（可选）：是否使用代理
    local temp_file="/tmp/download_temp"
    local use_proxy=$3     # 第三个参数（可选）：是否使用代理

    curl --connect-timeout 10 ${use_proxy:+--proxy $_PROXY} "$1" -o "$temp_file" > /dev/null 2>&1
    [ $? -ne 0 ] && return 1

    # 检查文件大小是否大于 32 字节
    local file_size=$(get_file_size $temp_file)
    if [ -z "$file_size" ] || [ "$file_size" -le 32 ]; then
        rm -f "$temp_file"
        return 1
    fi

    # 替换目标文件
    mv "$temp_file" "$2"
    return 0
}

if [ "$1" != "--noupdate" ]; then
        if download_file $URL_SCRIPT $0; then
                echo_log "update $0 succeeded."
                exec sh $0 --noupdate
                exit 0
        else
                echo_log "update $0 failed."
        fi
fi
#----------------------------------------------------
echo_log "...update clash start."

if [ -e "$DIR_SCRIPT/local.conf" ]; then
        if download_file $URL_CONFIG "$DIR_SCRIPT/config.new" 1; then
                replace_strings_from_config local.conf
                sed -i $SED_EXPR "$DIR_SCRIPT/config.new"
                
                mv -f "$DIR_SCRIPT/config.yaml" "$DIR_SCRIPT/config.yaml.bak"
                mv -f "$DIR_SCRIPT/config.new" "$DIR_SCRIPT/config.yaml"
        fi
fi

echo_log "...update clash done."
