#!/bin/sh

URL_SCRIPT="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/update-proxy-rule.sh"
DIR_SCRIPT="$(cd "$(dirname "$0")" && pwd)"
source $DIR_SCRIPT"/common.sh"
#----------------------------------------------------
echo_log "update clash proxy & rules."

echo_log "update TaiWan proxy..."
curl -X PUT  http://127.0.0.1:3721/providers/proxies/TaiWan
sleep 2s

echo_log "update HongKong proxy..."
curl -X PUT  http://127.0.0.1:3721/providers/proxies/HongKong
sleep 2s

echo_log "update gpt rules..."
curl -X PUT  http://127.0.0.1:3721/providers/rules/rule_gpt
