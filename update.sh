#!/bin/sh

_dir=$(cd $(dirname $0); pwd)

sh $_dir"/agh/update.sh"
sh $_dir"/clash/update.sh"

/etc/init.d/proxy restart
