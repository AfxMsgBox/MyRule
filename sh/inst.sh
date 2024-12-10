#!/bin/sh
#wget -O- https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/inst.sh|sh
URL_COMMON_SH="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/common.sh"
URL_KEEPLIVE="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/keeplive.sh"
URL_UPDATE_AGH="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/update-agh-config.sh"
URL_UPDATE_ALL="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/update-all.sh"
URL_UPDATE_CLASH="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/update-clash-config.sh"
URL_UPDATE_META="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/update-meta-config.sh"
URL_UPDATE_PROXY_RULE="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/update-proxy-rule.sh"

_download(){
  wget $1 -O $(basename $2)
}
_download $URL_COMMON_SH
_download $URL_KEEPLIVE
_download $URL_UPDATE_AGH
_download $URL_UPDATE_ALL
_download $URL_UPDATE_CLASH
_download $URL_UPDATE_META
_download $URL_UPDATE_PROXY_RULE
