#!/bin/sh

URL_SCRIPT="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/agh/update.sh"
URL_MYUPSTREAM="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/agh/myupstream.txt"
URL_MYPROXYLIST="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/domain/myproxylist.txt"
URL_GPT="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/domain/gpt.txt"
URL_NOTCN="https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/tld-not-cn.txt"
URL_GFWLIST="https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/gfw.txt"
DIR_SCRIPT="$(cd "$(dirname "$0")" && pwd)"

_PROXY="http://127.0.0.1:7890"

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
    if [ -z "$file_size" ] || [ "$file_size" -le 8 ]; then
        rm -f "$temp_file"
        return 1
    fi

    # 替换目标文件
    mv "$temp_file" "$2"
    return 0
}


#----------------------------------------------------
if [ "$1" != "--noupdate" ]; then
	if download_file $URL_SCRIPT $0; then
		echo_log "update $0 succeeded."
		exec sh $0 --noupdate
		exit 0
  	else
   		echo_log "update $0 failed."
	fi
fi

echo_log "...update agh start."

agh_dns=$DIR_SCRIPT"/dns.conf"

mkdir -p $DIR_SCRIPT"/download"
echo "# Generated at $(date '+%F %T')" > "$agh_dns"

#----------------------------------------------------
if [ -f "local.dns.conf" ]; then
  cat "local.dns.conf" >> "$agh_dns"
else
  echo "114.114.114.114" >> "$agh_dns"
fi
#----------------------------------------------------
echo_log "download MyUpStream."
download_file $URL_MYUPSTREAM "$DIR_SCRIPT/download/myupstream.txt" 1
if [ "$(get_file_size "$DIR_SCRIPT/download/myupstream.txt")" -gt 4 ]; then
    echo -e "\n# My Up Stream\n" >> "$agh_dns"
    cat "$DIR_SCRIPT/download/myupstream.txt" >> "$agh_dns"
fi

#----------------------------------------------------
echo_log "download MyProxyList."
download_file $URL_MYPROXYLIST "$DIR_SCRIPT/download/myproxylist.txt" 1
if [ "$(get_file_size "$DIR_SCRIPT/download/myproxylist.txt")" -gt 32 ]; then
    echo -e "\n# My Prox List\n" >> "$agh_dns"
    sed -En "s/^[ \t]*- '(\+\.)?([^']+)'$/[\/\2\/]127.0.0.1:253/p" "$DIR_SCRIPT/download/myproxylist.txt" >> "$agh_dns"
fi

#----------------------------------------------------
echo_log "download gpt."
download_file $URL_GPT "$DIR_SCRIPT/download/gpt.txt" 1
if [ "$(get_file_size "$DIR_SCRIPT/download/gpt.txt")" -gt 32 ]; then
    echo -e "\n# GPT List\n" >> "$agh_dns"
    sed -En "s/^[ \t]*- '(\+\.)?([^']+)'$/[\/\2\/]127.0.0.1:253/p" "$DIR_SCRIPT/download/gpt.txt" >> "$agh_dns"
fi

#----------------------------------------------------
echo_log "download not-cn."
download_file $URL_NOTCN "$DIR_SCRIPT/download/notcn.txt" 1
if [ "$(get_file_size "$DIR_SCRIPT/download/notcn.txt")" -gt 32 ]; then
    echo -e "\n# Not China Domian\n" >> "$agh_dns"
    sed -En "s/^[ \t]*- '(\+\.)?([^']+)'$/[\/\2\/]127.0.0.1:253/p" "$DIR_SCRIPT/download/notcn.txt" >> "$agh_dns"
    sed -i '/\[\/bj\/\]/d' "$agh_dns" #删除 [/.bj/]127.0.0.1:253
fi

#----------------------------------------------------
echo_log "download gfwlist."
download_file $URL_GFWLIST "$DIR_SCRIPT/download/gfwlist.txt" 1
if [ "$(get_file_size "$DIR_SCRIPT/download/gfwlist.txt")" -gt 32 ]; then
    echo -e "\n# GFW List\n" >> "$agh_dns"
    sed -En "s/^[ \t]*- '(\+\.)?([^']+)'$/[\/\2\/]127.0.0.1:253/p" "$DIR_SCRIPT/download/gfwlist.txt" >> "$agh_dns"
fi


echo_log "...update agh done."
exit 0
