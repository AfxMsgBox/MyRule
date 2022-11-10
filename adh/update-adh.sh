#!/bin/bash

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
} | sort | uniq -i > /root/adguardhome/gfwlist.txt.tmp

curl https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/adh/custom.dns.conf -o /root/adguardhome/custom.dns.conf.tmp

# generated file type
    echo "# Generated at $(date '+%F %T')" > /root/adguardhome/adguardhome.conf

    adh_dns="/root/adguardhome/dns.conf"
    local_dns="/root/adguardhome/local.dns.conf"
    custom_dns="/root/adguardhome/custom.dns.conf"
    gfwlist_txt="/root/adguardhome/gfwlist.txt"

    filesize=`ls -l /root/adguardhome/gfwlist.txt.tmp | awk '{print $5}'`
    if [ $filesize -gt 40960 ]; then
      if [ -f "$gfwlist_txt" ]; then rm "$gfwlist_txt"; fi
      mv /root/adguardhome/gfwlist.txt.tmp "$gfwlist_txt"
    else
      rm /root/adguardhome/gfwlist.txt.tmp
    fi

    filesize=`ls -l /root/adguardhome/custom.dns.conf.tmp | awk '{print $5}'`
    if [ $filesize -gt 200 ]; then
      if [ -f "$custom_dns" ]; then rm "$custom_dns"; fi
      mv /root/adguardhome/custom.dns.conf.tmp "$custom_dns"
    else
      rm /root/adguardhome/custom.dns.conf.tmp
    fi

    if [ -f "$local_dns" ]; then
      cat "$local_dns" >> "$adh_dns"
    else
      echo "192.168.1.1" >> "$adh_dns"
    fi

    if [ -f "$custom_dns" ]; then
      cat "$custom_dns" >> "$adh_dns"
    fi

    perl -pe "s@^.*+\$@[/$&/]127.0.0.1:253@" "$gfwlist_txt" >> "$adh_dns"
