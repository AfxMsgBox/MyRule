#!/bin/sh

URL_SCRIPT="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/update-agh-config.sh"
DIR_SCRIPT=$(dirname "$(readlink -f "$0")")
source $DIR_SCRIPT"/common.sh"
#----------------------------------------------------

URL_MYUPSTREAM="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/agh/myupstream.txt"
URL_MYPROXYLIST="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/domain/myproxylist.txt"
URL_GPT="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/domain/gpt.txt"
URL_NOTCN="https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/tld-not-cn.txt"
URL_GFWLIST="https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/gfw.txt"

DIR_AGH=$DIR_SCRIPT"/../agh"
agh_dns=$DIR_AGH"/dns.conf"
#----------------------------------------------------

mkdir -p $DIR_AGH"/download"

echo_log "update agh config start..."

echo "# Generated at $(date '+%F %T')" > "$agh_dns"
#----------------------------------------------------
if [ -f $DIR_AGH"/local.dns.conf" ]; then
  cat $DIR_AGH"/local.dns.conf" >> "$agh_dns"
else
  echo "223.5.5.5" >> "$agh_dns"
fi
#----------------------------------------------------
echo_log "  download MyUpStream."
download_file $URL_MYUPSTREAM "$DIR_AGH/download/myupstream.txt" 1
if [ "$(get_file_size "$DIR_AGH/download/myupstream.txt")" -gt 8 ]; then
    echo -e "\n# My Up Stream\n" >> "$agh_dns"
    cat "$DIR_AGH/download/myupstream.txt" >> "$agh_dns"
fi

#----------------------------------------------------
echo_log "  download MyProxyList."
download_file $URL_MYPROXYLIST "$DIR_AGH/download/myproxylist.txt" 1
if [ "$(get_file_size "$DIR_AGH/download/myproxylist.txt")" -gt 32 ]; then
    echo -e "\n# My Prox List\n" >> "$agh_dns"
    sed -En "s/^[ \t]*- '(\+\.)?([^']+)'$/[\/\2\/]127.0.0.1:253/p" "$DIR_AGH/download/myproxylist.txt" >> "$agh_dns"
fi

#----------------------------------------------------
echo_log "  download gpt."
download_file $URL_GPT "$DIR_AGH/download/gpt.txt" 1
if [ "$(get_file_size "$DIR_AGH/download/gpt.txt")" -gt 32 ]; then
    echo -e "\n# GPT List\n" >> "$agh_dns"
    sed -En "s/^[ \t]*- '(\+\.)?([^']+)'$/[\/\2\/]127.0.0.1:253/p" "$DIR_AGH/download/gpt.txt" >> "$agh_dns"
fi

#----------------------------------------------------
echo_log "  download not-cn."
download_file $URL_NOTCN "$DIR_AGH/download/notcn.txt" 1
if [ "$(get_file_size "$DIR_AGH/download/notcn.txt")" -gt 32 ]; then
    echo -e "\n# Not China Domian\n" >> "$agh_dns"
    sed -En "s/^[ \t]*- '(\+\.)?([^']+)'$/[\/\2\/]127.0.0.1:253/p" "$DIR_AGH/download/notcn.txt" >> "$agh_dns"
    sed -i '/\[\/bj\/\]/d' "$agh_dns" #删除 [/.bj/]127.0.0.1:253
fi

#----------------------------------------------------
echo_log "  download gfwlist."
download_file $URL_GFWLIST "$DIR_AGH/download/gfwlist.txt" 1
if [ "$(get_file_size "$DIR_AGH/download/gfwlist.txt")" -gt 32 ]; then
    echo -e "\n# GFW List\n" >> "$agh_dns"
    sed -En "s/^[ \t]*- '(\+\.)?([^']+)'$/[\/\2\/]127.0.0.1:253/p" "$DIR_AGH/download/gfwlist.txt" >> "$agh_dns"
fi

echo_log "update agh config done."
exit 0
