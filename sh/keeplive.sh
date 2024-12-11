#!/bin/sh
#*/5 * * * *  sh /etc/proxy/sh/keeplive.sh
curl --connect-timeout 5 --proxy http://127.0.0.1:7890 -I https://www.google.com > /dev/null 2>&1
curl --connect-timeout 5 --proxy http://127.0.0.1:7890 -I https://www.chatgpt.com > /dev/null 2>&1

