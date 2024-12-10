#!/bin/sh
#----------------------------------------------------

get_file_size() { [ -f "$1" ] && ls -l "$1" | awk '{print $5}' || echo 0; }
echo_log() { [ $# -eq 1 ] && set -- "$1" "$1"; echo "$1" && logger "$2"; }

download_file() { 
#下载URL 目标文件名  bUseProxy=1（可选）
    local url="${1:?Error: URL is required}"   # 第一个参数必须存在，否则报错并退出
    local filename="${2:?Error: Filename is required}"  # 第二个参数必须存在
    local use_proxy="${3:-1}"                 # 第三个参数默认值为 1

    local temp_file="/tmp/download_temp"
    locla url_proxy="http://127.0.0.1:7890"
 
    curl --connect-timeout 10 ${use_proxy:+--proxy $url_proxy} "$1" -o "$temp_file" > /dev/null 2>&1
    [ $? -ne 0 ] && return 1

    # 检查文件大小是否大于 8 字节
    local file_size=$(get_file_size $temp_file)
    if [ -z "$file_size" ] || [ "$file_size" -le 8 ]; then
        rm -f "$temp_file"
        return 1
    fi

    # 替换目标文件
    mv "$temp_file" "$2"
    return 0
}

if [ "$1" != "--noupdate" ] && [ -n "$URL_SCRIPT" ]; then
	if download_file $URL_SCRIPT $0; then
		echo_log "update script $0 succeeded."
		exec sh $0 --noupdate
		exit 0
	else
		echo_log "update script $0 failed."
	fi
fi

#------------------------------------------------------
replace_strings_from_config() {
#configfile destfile
    local SED_EXPR=""
    local CONFIG_FILE="$1"

    # 从配置文件中读取所有的键值对并构建 sed 表达式
    while IFS='=' read -r key value; do
        # 跳过空行或无效行
        if [ -z "$key" ] || [ -z "$value" ]; then
            continue
        fi

        # 转义特殊字符
        local ESCAPED_KEY=$(printf '%s\n' "$key" | sed -e 's/[][\/.^$*]/\\&/g')
        local ESCAPED_VALUE=$(printf '%s\n' "$value" | sed -e 's/[&\\/]/\\&/g')

        # 构建 sed 表达式
        SED_EXPR="${SED_EXPR}s|{${ESCAPED_KEY}}|${ESCAPED_VALUE}|g;"
    done < "$CONFIG_FILE"

    replace_strings_from_config "$DIR_SCRIPT/local.conf"
    sed -i $SED_EXPR $2
}
