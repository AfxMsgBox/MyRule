#!/bin/sh

URL_COMMON_SH="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/common.sh"
URL_KEEPLIVE="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/keeplive.sh"
URL_UPDATE_AGH="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/update-agh-config.sh"
URL_UPDATE_ALL="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/update-all.sh"
URL_UPDATE_CLASH="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/update-clash-config.sh"
URL_UPDATE_META="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/update-meta-config.sh"
URL_UPDATE_PROXY_RULE="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/update-proxy-rule.sh"

wget $URL_COMMON_SH
wget $URL_KEEPLIVE
wget $URL_UPDATE_AGH
wget $URL_UPDATE_ALL
wget $URL_UPDATE_CLASH
wget $URL_UPDATE_META
wget $URL_UPDATE_PROXY_RULE
