#!/bin/sh

agh_dir=$(cd $(dirname $0); pwd)"/"

cd $agh_dir

if [ -f $agh_dir"update-agh.sh" ]; then mv $agh_dir"update-agh.sh" $agh_dir"update-agh.sh.bak"; fi
curl --proxy http://127.0.0.1:7890 https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/agh/update-agh.sh -o $agh_dir"update-agh.sh"

chmod +x $agh_dir"update-agh.sh"
$agh_dir"update-agh.sh"

if [ -f "/etc/init.d/adguardhome" ]; then
  /etc/init.d/adguardhome restart
fi
