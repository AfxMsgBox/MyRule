#!/bin/sh

URL_COMMON_SH="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/common.sh"
URL_KEEPLIVE="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/keeplive.sh"
URL_UPDATE_AGH="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/update-agh-config.sh"
URL_UPDATE_ALL="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/update-all-configs.sh"
URL_UPDATE_CLASH="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/update-clash-config.sh"
URL_UPDATE_META="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/update-meta-config.sh"
URL_UPDATE_PROXY_RULE="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/update-proxy-rule.sh"
URL_HOTPLUG_TUN="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/etc/hotplug.d/net/99-meta-route"
#URL_INIT_D_PROXY="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/etc/init.d/proxy"
URL_INIT_D_CLASH_META="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/etc/init.d/clash_meta"
URL_INIT_D_AGH="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/etc/init.d/agh"

URL_DOWNLOAD_ALL_SCRIPT_SH="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/download-all-script.sh"
URL_INTST_SH="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/inst.sh"

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

#mkdir -p ./etc/init.d
#mkdir -p ./etc/hotplug.d/net
wget $URL_HOTPLUG_TUN -O /etc/hotplug.d/net/99-meta-route
#wget $URL_INIT_D_PROXY -O /etc/init.d/proxy
wget $URL_INIT_D_CLASH_META -O /etc/init.d/clash_meta
wget $URL_INIT_D_AGH -O /etc/init.d/agh
chmod +x /etc/init.d/clash_meta
chmod +x /etc/init.d/agh

_download $URL_DOWNLOAD_ALL_SCRIPT_SH
#最后把inst也更新一下
_download $URL_INTST_SH 
