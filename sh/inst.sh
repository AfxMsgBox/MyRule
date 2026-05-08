#!/bin/sh
# 一键安装入口；等价于直接运行 download-all-scripts.sh。
# 同样可通过环境变量覆盖仓库根：
#   MP_REPO_RAW_URL=https://my.fork.example/raw \
#       wget -O- https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/inst.sh | sh
wget -O- "${MP_REPO_RAW_URL:-https://raw.githubusercontent.com/AfxMsgBox/MyRule/main}/sh/download-all-scripts.sh" | sh
