#!/bin/bash

#agh_dir=$(cd $(dirname ${BASH_SOURCE[0]}); pwd)"/"
agh_dir=$(cd $(dirname $0); pwd)"/"

cd $agh_dir

#if [ -f $agh_dir"dns.conf" ]; then mv $agh_dir"dns.conf" $agh_dir"dns.conf.bak"; fi

#echo "127.0.0.1:253" > $agh_dir"dns.conf"
#/etc/init.d/adguardhome restart

if [ -f $agh_dir"update-agh.sh" ]; then mv $agh_dir"update-agh.sh" $agh_dir"update-agh.sh.bak"; fi
curl https://ghproxy.com/https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/agh/update-agh.sh -o $agh_dir"update-agh.sh"

chmod +x $agh_dir"update-agh.sh"
$agh_dir"update-agh.sh"

/etc/init.d/proxy restart
