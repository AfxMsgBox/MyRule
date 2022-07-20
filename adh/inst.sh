#!/bin/bash

if [ -f "./adguardhome.conf" ]; then mv ./adguardhome.conf ./adguardhome.conf.bak; fi

echo "127.0.0.1:253" > adguardhome.conf
/etc/init.d/adguardhome restart
curl https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/adh/update-adh.sh -o ./update-adh.sh
chmod +x ./update-adh.sh
./update-adh.sh
