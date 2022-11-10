#!/bin/bash

if [ -f "./dns.conf" ]; then mv ./dns.conf ./dns.conf.bak; fi

echo "127.0.0.1:253" > dns.conf
/etc/init.d/adguardhome restart
curl https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/adh/update-adh.sh -o ./update-adh.sh
chmod +x ./update-adh.sh
./update-adh.sh
