#!/bin/sh

./agh/update.sh
./clash/update.sh

/etc/init.d/proxy restart
