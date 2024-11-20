#!/bin/sh

#agh_dir=$(cd $(dirname ${BASH_SOURCE[0]}); pwd)"/"
agh_dir=$(cd $(dirname $0); pwd)"/"
agh_dns=$agh_dir"dns.conf"
local_dns=$agh_dir"local.dns.conf"
custom_dns=$agh_dir"custom.dns.conf"
gfwlist_dns=$agh_dir"gfwlist.dns.conf"

# check dependency
command -v curl &>/dev/null || { echo "curl is not installed in this system" 1>&2; exit 1; }
command -v perl &>/dev/null || { echo "perl is not installed in this system" 1>&2; exit 1; }
command -v base64 &>/dev/null || { echo "base64 is not installed in this system" 1>&2; exit 1; }

# convert gfwlist.txt
base64 -d       </dev/null &>/dev/null && base64='base64 -d'
base64 --decode </dev/null &>/dev/null && base64='base64 --decode'
[ "$base64" ] || { echo "[ERR] Command not found: 'base64'" 1>&2; exit 1; }
curl -4sSkL --proxy http://127.0.0.1:7890 https://raw.github.com/gfwlist/gfwlist/master/gfwlist.txt | $base64 | { perl -pe '
if (/URL Keywords/i) { $null = <> until $null =~ /^!/ }
s#^\s*+$|^!.*+$|^@@.*+$|^\[AutoProxy.*+$|^/.*/$##i;
s@^\|\|?|\|$@@;
s@^https?:/?/?@@i;
s@(?:/|%).*+$@@;
s@\*[^.*]++$@\n@;
s@^.*?\*[^.]*+(?=[^*]+$)@@;
s@^\*?\.|^.*\.\*?$@@;
s@(?=[^0-9a-zA-Z.-]).*+$@@;
s@^\d+\.\d+\.\d+\.\d+(?::\d+)?$@@;
s@^\s*+$@@'
} | sort | uniq -i > /tmp/gfwlist_dns.tmp

curl --proxy http://127.0.0.1:7890 https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/agh/custom.dns.conf -o /tmp/custom_dns.tmp


filesize=`ls -l /tmp/gfwlist_dns.tmp | awk '{print $5}'`
if [ $filesize -gt 40960 ]; then
  mv -f /tmp/gfwlist_dns.tmp "$gfwlist_dns"
else
  rm /tmp/gfwlist_dns.tmp
fi

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

perl -pe "s@^.*+\$@[/$&/]127.0.0.1:253@" "$gfwlist_dns" >> "$agh_dns"

curl --proxy http://127.0.0.1:7890 https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/tld-not-cn.txt |  sed -En "s/^[ \t]*- '(\+\.)?([^']+)'$/[\/\2\/]127.0.0.1:253/p" >> "$agh_dns"
