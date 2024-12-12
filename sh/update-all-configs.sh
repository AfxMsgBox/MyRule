#!/bin/sh
#----------------------------------------------------
DIR_SCRIPT=$(dirname "$(readlink -f "$0")")
#直接调用common.sh，来升级common.sh
sh $DIR_SCRIPT"/common.sh"

URL_SCRIPT="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/update-all-configs.sh"
#引用common.sh来升级自己
source $DIR_SCRIPT"/common.sh"

#----------------------------------------------------
URL_UPDATE_AGH="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/update-agh-config.sh"
URL_UPDATE_CLASH="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/update-clash-config.sh"
URL_UPDATE_META="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/update-meta-config.sh"
URL_UPDATE_PROXY_RULE="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/update-proxy-rule.sh"

#----------------------------------------------------
echo_log "update all configs"

download_file $URL_UPDATE_AGH $DIR_SCRIPT"/update-agh-config.sh" 1
sh $DIR_SCRIPT"/update-agh-config.sh" --noupdate

download_file $URL_UPDATE_CLASH $DIR_SCRIPT"/update-clash-config.sh" 1
sh $DIR_SCRIPT"/update-clash-config.sh" --noupdate

download_file $URL_UPDATE_META $DIR_SCRIPT"/update-meta-config.sh" 1
sh $DIR_SCRIPT"/update-meta-config.sh" --noupdate

download_file $URL_UPDATE_PROXY_RULE $DIR_SCRIPT"/update-proxy-rule.sh" 1
sh $DIR_SCRIPT"/update-proxy-rule.sh" --noupdate

echo_log "all done."
