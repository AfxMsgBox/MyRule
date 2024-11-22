#!/bin/sh

curl --connect-timeout 5 -I https://www.google.com > /dev/null 2>&1
