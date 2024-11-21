#!/bin/sh
#----------------------------------------------------
get_file_size() { [ -f "$1" ] && ls -l "$1" | awk '{print $5}' || echo 0; }

download_file() { 
	#下载URL 目标文件名  1（可选）：是否使用代理
    local temp_file="/tmp/download_temp"
    local use_proxy=$3     # 第三个参数（可选）：是否使用代理

    curl --connect-timeout 10 ${use_proxy:+--proxy $_PROXY} "$1" -o "$temp_file" > /dev/null 2>&1
    [ $? -ne 0 ] && echo "Download failed." && return 1

    # 检查文件大小是否大于 32 字节
    local file_size=$(get_file_size $temp_file)
    if [ -z "$file_size" ] || [ "$file_size" -le 32 ]; then
        echo "Downloaded file is too small or missing."
        rm -f "$temp_file"
        return 1
    fi

    # 替换目标文件
    mv "$temp_file" "$2"
    echo "Download succeeded, file saved to $2."
    return 0
}

#----------------------------------------------------
URL_SCRIPT="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/update.sh"

if [ "$1" != "--noupdate" ]; then
	if download_file $URL_SCRIPT $0; then
		echo "update script done, exec new script "$0"."
		exec sh $0 --noupdate
		exit 0
	fi
fi

_dir=$(cd $(dirname $0); pwd)

sh $_dir"/agh/update.sh"
sh $_dir"/clash/update.sh"

/etc/init.d/proxy restart
