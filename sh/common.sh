#!/bin/sh
PATH_SCRIPT=$(readlink -f "$0")
DIR_SCRIPT=$(dirname "$PATH_SCRIPT")
_URL_COMMON_SH="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/common.sh"
#----------------------------------------------------
get_file_size() { [ -f "$1" ] && ls -l "$1" | awk '{print $5}' || echo 0; }
echo_log() { [ $# -eq 1 ] && set -- "$1" "$1"; echo "$1" && logger "$2"; }

download_file() { 
#下载URL 目标文件名  bUseProxy=1（可选）
    local url="${1:?Error: URL is required}"   # 第一个参数必须存在，否则报错并退出
    local filename="${2:?Error: Filename is required}"  # 第二个参数必须存在
    local use_proxy="${3:-1}"                 # 第三个参数默认值为 1

    local temp_file="/tmp/download_temp"
    local url_proxy="http://127.0.0.1:7890"
 
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

#------------------------------------------------------
replace_strings_from_config() {
    local config_file="$1"
    local target_file="$2"

    # 基础校验：确保文件均存在
    [ ! -f "$config_file" ] || [ ! -f "$target_file" ] && return 1

    awk '
    # 阶段1：读取配置文件 (NR==FNR 表示当前正在处理第一个文件)
    NR == FNR {
        idx = index($0, "=")
        if (idx > 0) {
            # 以第一个 "=" 为界限进行严格切分
            k = substr($0, 1, idx-1)
            v = substr($0, idx+1)
            # 构建映射字典，键名加上花括号
            map["{" k "}"] = v
        }
        next
    }
    # 阶段2：处理目标模板文件
    {
        line = $0
        for (k in map) {
            out = ""
            rem = line
            # 使用纯粹的索引查找，避免死循环和正则注入
            while ((idx = index(rem, k)) > 0) {
                out = out substr(rem, 1, idx-1) map[k]
                rem = substr(rem, idx+length(k))
            }
            line = out rem
        }
        print line
    }
    ' "$config_file" "$target_file" > "${target_file}.tmp" && mv "${target_file}.tmp" "$target_file"
}
#------------------------------------------------------

_URL_SCRIPT="${URL_SCRIPT:-$_URL_COMMON_SH}"  

if [ "$1" != "--noupdate" ] && [ -n "$_URL_SCRIPT" ]; then
	if download_file $_URL_SCRIPT $PATH_SCRIPT; then
		echo_log "update script $PATH_SCRIPT succeeded."
		exec sh $PATH_SCRIPT --noupdate
		exit 0
	else
		echo_log "update script $PATH_SCRIPT failed."
	fi
fi
