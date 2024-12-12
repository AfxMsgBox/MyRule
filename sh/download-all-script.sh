#!/bin/sh

URL_COMMON_SH="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/common.sh"
URL_KEEPLIVE="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/keeplive.sh"
URL_UPDATE_AGH="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/update-agh-config.sh"
URL_UPDATE_ALL="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/update-all.sh"
URL_UPDATE_CLASH="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/update-clash-config.sh"
URL_UPDATE_META="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/update-meta-config.sh"
URL_UPDATE_PROXY_RULE="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/update-proxy-rule.sh"
URL_HOTPLUG_TUN="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/etc/hotplug.d/net/99-meta-route"
URL_INIT_D_PROXY="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/etc/init.d/proxy"
URL_INIT_D_CLASH_META="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/etc/init.d/clash_meta"
URL_INIT_D_AGH="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/etc/init.d/agh"

_download(){
  wget $1 -O $(basename $1)
}
_download $URL_COMMON_SH
_download $URL_KEEPLIVE
_download $URL_UPDATE_AGH
_download $URL_UPDATE_ALL
_download $URL_UPDATE_CLASH
_download $URL_UPDATE_META
_download $URL_UPDATE_PROXY_RULE
_download $URL_HOTPLUG_TUN
_download $URL_INIT_D_PROXY
_download $URL_INIT_D_CLASH_META
_download $URL_INIT_D_AGH
