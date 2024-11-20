#!/bin/sh

agh_dir=$(cd $(dirname $0); pwd)
agh_dns=$agh_dir/"dns.conf"
local_dns=$agh_dir/"local.dns.conf"
custom_dns=$agh_dir/"custom.dns.conf"

# check dependency
command -v curl &>/dev/null || { echo "curl is not installed in this system" 1>&2; exit 1; }

curl --proxy http://127.0.0.1:7890 https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/agh/custom.dns.conf -o /tmp/custom_dns.tmp
filesize=`ls -l /tmp/custom_dns.tmp | awk '{print $5}'`
if [ $filesize -gt 200 ]; then
  mv -f /tmp/custom_dns.tmp "$custom_dns"
else
  rm /tmp/custom_dns.tmp
fi

echo "# Generated at $(date '+%F %T')" > "$agh_dns"

if [ -f "$local_dns" ]; then
  cat "$local_dns" >> "$agh_dns"
else
  echo "114.114.114.114" >> "$agh_dns"
fi

if [ -f "$custom_dns" ]; then
  cat "$custom_dns" >> "$agh_dns"
fi

curl --proxy http://127.0.0.1:7890 https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/tld-not-cn.txt | sed -En "s/^[ \t]*- '(\+\.)?([^']+)'$/[\/\2\/]127.0.0.1:253/p" >> "$agh_dns"
curl --proxy http://127.0.0.1:7890 https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/gfw.txt        | sed -En "s/^[ \t]*- '(\+\.)?([^']+)'$/[\/\2\/]127.0.0.1:253/p" >> "$agh_dns"
