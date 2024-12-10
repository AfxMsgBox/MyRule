#!/bin/sh
URL_SCRIPT="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/update-meta-config.sh"
URL_CONFIG="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/meta/config.yaml"

DIR_SCRIPT="$(cd "$(dirname "$0")" && pwd)"
source $DIR_SCRIPT"/common.sh"

#----------------------------------------------------
echo_log "update clash config file."

if [ -e "$DIR_SCRIPT/local.conf" ]; then
        if download_file $URL_CONFIG "$DIR_SCRIPT/config.new" 1; then
                replace_strings_from_config "$DIR_SCRIPT../meta/local.conf" "$DIR_SCRIPT/config.new"
                
                mv -f "$DIR_SCRIPT/../meta/config.yaml" "$DIR_SCRIPT/../meta/config.yaml.bak" > /dev/null 2>&1
                mv -f "$DIR_SCRIPT/config.new" "$DIR_SCRIPT/../meta/config.yaml" > /dev/null 2>&1
        fi
fi
