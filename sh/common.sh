#!/bin/sh
#----------------------------------------------------
__PROXY="http://127.0.0.1:7890"

get_file_size() { [ -f "$1" ] && ls -l "$1" | awk '{print $5}' || echo 0; }
echo_log() { [ $# -eq 1 ] && set -- "$1" "$1"; echo "$1" && logger "$2"; }

download_file() { 
	#下载URL 目标文件名  1（可选）：是否使用代理
    local temp_file="/tmp/download_temp"
    local use_proxy=$3     # 第三个参数（可选）：是否使用代理

    curl --connect-timeout 10 ${use_proxy:+--proxy $__PROXY} "$1" -o "$temp_file" > /dev/null 2>&1
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
