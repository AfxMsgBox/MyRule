#!/bin/bash

adh_dns="/root/adguardhome/dns.conf"
local_dns="/root/adguardhome/local.dns.conf"
custom_dns="/root/adguardhome/custom.dns.conf"
gfwlist_dns="/root/adguardhome/gfwlist.dns.conf"

# check dependency
command -v curl &>/dev/null || { echo "curl is not installed in this system" 1>&2; exit 1; }
command -v perl &>/dev/null || { echo "perl is not installed in this system" 1>&2; exit 1; }
command -v base64 &>/dev/null || { echo "base64 is not installed in this system" 1>&2; exit 1; }

# convert gfwlist.txt
base64 -d       </dev/null &>/dev/null && base64='base64 -d'
base64 --decode </dev/null &>/dev/null && base64='base64 --decode'
[ "$base64" ] || { echo "[ERR] Command not found: 'base64'" 1>&2; exit 1; }
curl -4sSkL https://raw.github.com/gfwlist/gfwlist/master/gfwlist.txt | $base64 | { perl -pe '
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
} | sort | uniq -i > $gfwlist_dns".tmp"

curl https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/adh/custom.dns.conf -o $custom_dns".tmp"


filesize=`ls -l $gfwlist_dns".tmp" | awk '{print $5}'`
if [ $filesize -gt 40960 ]; then
  mv -f $gfwlist_dns".tmp" "$gfwlist_dns"
else
  rm $gfwlist_dns".tmp"
fi

filesize=`ls -l $custom_dns".tmp" | awk '{print $5}'`
if [ $filesize -gt 200 ]; then
  mv -f $custom_dns".tmp" "$custom_dns"
else
  rm $custom_dns".tmp"
fi

echo "# Generated at $(date '+%F %T')" > "$adh_dns"

if [ -f "$local_dns" ]; then
  cat "$local_dns" >> "$adh_dns"
else
  echo "114.114.114.114" >> "$adh_dns"
fi

perl -pe "s@^.*+\$@[/$&/]127.0.0.1:253@" "$gfwlist_dns" >> "$adh_dns"

if [ -f "$custom_dns" ]; then
  cat "$custom_dns" >> "$adh_dns"
fi
