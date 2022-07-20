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
} | sort | uniq -i > ./gfwlist.txt.tmp

curl https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/adh/adh_add.conf -o ./adh_add.conf.tmp

# generated file type
    echo "# Generated at $(date '+%F %T')" > ./adguardhome.conf

#    echo "202.96.134.133" >> ./adguardhome.conf
#    echo "202.96.128.166" >> ./adguardhome.conf


    local_dns="./local.dns.conf"
    adh_conf="./adguardhome.conf"
    adh_add="./adh_add.conf"
    gfwlist_txt="./gfwlist.txt"

    filesize=`ls -l ./gfwlist.txt.tmp | awk '{print $5}'`
    if [ $filesize -gt 40960 ]; then
      if [ -f "$gfwlist_txt" ]; then rm "$gfwlist_txt"; fi
      mv ./gfwlist.txt.tmp "$gfwlist_txt"
    else
      rm ./gfwlist.txt.tmp
    fi

    filesize=`ls -l ./adh_add.conf.tmp | awk '{print $5}'`
    if [ $filesize -gt 200 ]; then
      if [ -f "$adh_add" ]; then rm "$adh_add"; fi
      mv ./adh_add.conf.tmp "$adh_add"
    else
      rm ./adh_ad.conf.tmp
    fi
    
    if [ -f "$local_dns" ]; then
      cat "$local_dns" >> "$adh_conf"
    else
      echo "192.168.1.1" >> "$adh_conf"
    fi

    if [ -f "$adh_add" ]; then
      cat "$adh_add" >> "$adh_conf"
    fi

    perl -pe "s@^.*+\$@[/$&/]127.0.0.1:253@" "$gfwlist_txt" >> "$adh_conf"

    /etc/init.d/adguardhome restart
