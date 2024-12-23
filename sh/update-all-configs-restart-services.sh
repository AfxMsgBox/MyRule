#!/bin/sh

URL_SCRIPT="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/update-all-configs-restart-services.sh"
DIR_SCRIPT=$(dirname "$(readlink -f "$0")")
source $DIR_SCRIPT"/common.sh"
#----------------------------------------------------

sh $DIR_SCRIPT"/update-all-configs.sh"
service agh restart
service clash_meta restart
