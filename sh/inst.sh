#!/bin/sh
# 一键安装入口。等价于：
#   wget -O- <repo>/sh/download-all-scripts.sh | sh
# 调试常用：
#   curl -X POST http://127.0.0.1:3721/cache/fakeip/flush && ping www.google.com
wget -O- https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/download-all-scripts.sh | sh
