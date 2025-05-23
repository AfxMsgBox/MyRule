#!/bin/sh

URL_SCRIPT="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/update-meta-config.sh"
DIR_SCRIPT=$(dirname "$(readlink -f "$0")")
source $DIR_SCRIPT"/common.sh"
#----------------------------------------------------

URL_CONFIG="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/meta/config.yaml"
DIR_CONFIG=$DIR_SCRIPT"/../meta"
#----------------------------------------------------

echo_log "update clash config file."

if [ -e "$DIR_CONFIG/local.conf" ]; then
        if download_file $URL_CONFIG "$DIR_CONFIG/config.new" 1; then
                replace_strings_from_config "$DIR_CONFIG/local.conf" "$DIR_CONFIG/config.new"
                
                mv -f "$DIR_CONFIG/config.yaml" "$DIR_CONFIG/config.yaml.bak" > /dev/null 2>&1
                mv -f "$DIR_CONFIG/config.new"  "$DIR_CONFIG/config.yaml" > /dev/null 2>&1
        fi
fi
