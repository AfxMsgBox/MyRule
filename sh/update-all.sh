#!/bin/sh

URL_SCRIPT="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/update-all.sh"
DIR_SCRIPT=$(dirname "$(readlink -f "$0")")
source $DIR_SCRIPT"/common.sh"

URL_UPDATE_AGH="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/update-agh-config.sh"
URL_UPDATE_CLASH="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/update-clash-config.sh"
URL_UPDATE_META="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/update-meta-config.sh"
URL_UPDATE_PROXY_RULE="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/update-proxy-rule.sh"
URL_KEEPLIVE="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/keeplive.sh"
#----------------------------------------------------
echo_log "update keeplive.sh"
download_file $URL_KEEPLIVE $DIR_SCRIPT"/keeplive.sh" 1

if [ ! -e "$DIR_SCRIPT/update-agh-config.sh" ]; then
    download_file $URL_UPDATE_AGH $DIR_SCRIPT"/agh/update-config.sh" 1
    sh $DIR_SCRIPT"/update-agh-config.sh" --noupdate
else
    sh $DIR_SCRIPT"/update-agh-config.sh"
fi

if [ ! -e "$DIR_SCRIPT/update-clash-config.sh" ]; then
    download_file $URL_UPDATE_CLASH $DIR_SCRIPT"/update-clash-config.sh" 1
    sh $DIR_SCRIPT"/update-clash-config.sh" --noupdate
else
    sh $DIR_SCRIPT"/update-clash-config.sh"
fi

if [ ! -e "$DIR_SCRIPT/update-meta-config.sh" ]; then
    download_file $URL_UPDATE_META $DIR_SCRIPT"/update-meta-config.sh" 1
    sh $DIR_SCRIPT"/update-meta-config.sh" --noupdate
else
    sh $DIR_SCRIPT"/update-meta-config.sh"
fi

echo_log "restart proxy ..."
/etc/init.d/proxy restart
sleep 2s

if [ ! -e "$DIR_SCRIPT/update-proxy-rule.sh" ]; then
    download_file $URL_UPDATE_PROXY_RULE $DIR_SCRIPT"/update-proxy-rule.sh" 1
    sh $DIR_SCRIPT"/update-proxy-rule.sh" --noupdate
else
    sh $DIR_SCRIPT"/update-proxy-rule.sh"
fi

echo_log "all done."
