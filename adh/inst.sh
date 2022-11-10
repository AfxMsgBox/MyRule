#!/bin/bash

if [ -f "/root/adguardhome/dns.conf" ]; then mv /root/adguardhome/dns.conf /root/adguardhome/dns.conf.bak; fi
echo "127.0.0.1:253" > /root/adguardhome/dns.conf
/etc/init.d/adguardhome restart

if [ -f "/root/adguardhome/update-adh.sh" ]; then mv /root/adguardhome/update-adh.sh /root/adguardhome/update-adh.sh.bak; fi
curl https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/adh/update-adh.sh -o /root/adguardhome/update-adh.sh

chmod +x /root/adguardhome/update-adh.sh
/root/adguardhome/update-adh.sh

/etc/init.d/adguardhome restart
