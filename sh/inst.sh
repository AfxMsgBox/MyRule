#!/bin/sh
# MyProxy 一键安装：下载所有脚本与服务文件，刷新配置，启用并启动服务。
# 前提：本机已按默认路径装好 mihomo（/etc/proxy/core/mihomo）
#       与 AdGuardHome（/usr/bin/AdGuardHome）；如不一致请改 env.local.conf。
#
# 用法（需 root；安装目录作为第一个参数，省略则默认 /etc/proxy/sh）：
#   sh inst.sh                    # 装到 /etc/proxy/sh
#   sh inst.sh /opt/myproxy/sh    # 装到自定义目录
# wget|sh 管道时用 sh -s -- 传位置参数：
#   wget -O- https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/inst.sh | sh
#   wget -O- https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/inst.sh | sh -s -- /opt/myproxy/sh
# 自托管 / 分支调试：
#   MP_REPO_RAW_URL=https://my.fork.example/raw \
#       wget -O- $MP_REPO_RAW_URL/sh/inst.sh | sh

# 必须 root 才能写 /etc/init.d、/etc/systemd/system 等
[ "$(id -u)" = "0" ] || { echo "需要 root 权限运行（Debian/Ubuntu 请加 sudo）" >&2; exit 1; }

# 安装目录：第一个位置参数 > 默认 /etc/proxy/sh
DIR_SH="${1:-/etc/proxy/sh}"

# 引导阶段先尝试加载本地已有的 env.local.conf（开发场景下用户可在此预置
# MP_REPO_RAW_URL=https://...branch 让 inst 直接拉分支版本）
[ -f "$DIR_SH/env.local.conf" ] && . "$DIR_SH/env.local.conf"

# 仓库 raw 根；env.local.conf / 命令行环境变量都可覆盖；最终默认 main
MP_REPO_RAW_URL="${MP_REPO_RAW_URL:-https://raw.githubusercontent.com/AfxMsgBox/MyRule/main}"

# 识别 OS：openwrt | systemd，可通过 OS_TYPE 环境变量强制
if [ -n "$OS_TYPE" ]; then
    :
elif [ -f /etc/openwrt_release ] || grep -qs '^ID=.*openwrt' /etc/os-release; then
    OS_TYPE=openwrt
elif command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ]; then
    OS_TYPE=systemd
else
    echo "未识别的系统；用 OS_TYPE=openwrt 或 OS_TYPE=systemd 强制" >&2
    exit 1
fi
echo "目标系统：$OS_TYPE"

# === 第 1 步：用 wget 引导下载 env.conf 与 common.sh（这两个文件必须先就位） ===
echo
echo ">>> 引导下载 env.conf / common.sh"
mkdir -p "$DIR_SH"
wget -q -O "$DIR_SH/env.conf"  "$MP_REPO_RAW_URL/sh/env.conf"  || { echo "下载 env.conf 失败"  >&2; exit 1; }
wget -q -O "$DIR_SH/common.sh" "$MP_REPO_RAW_URL/sh/common.sh" || { echo "下载 common.sh 失败" >&2; exit 1; }

# inst.sh 已经用 wget 下载了 env.conf 与 common.sh，告诉后续脚本不必再下
# （_DEPS_UPDATED 是 common.sh 内部约定的运行时标记，不是 env.conf 配置项，
# 所以不带 MP_ 前缀）
export _DEPS_UPDATED=1
# 加载 env + 公共函数；不设 url_self，common.sh 自动跳过自更新
. "$DIR_SH/common.sh"

# === 第 2 步：用 download_file 拉其它公共脚本（享受代理回退 / --fail / 重试） ===
echo_log ">>> 下载脚本到 $DIR_SH"
for name in keeplive.sh setup-fake-ip-route.sh \
            update-agh-config.sh update-all-configs.sh \
            update-all-configs-restart-services.sh \
            update-core-config.sh update-proxy-rule.sh inst.sh; do
    download_file "$MP_REPO_RAW_URL/sh/$name" "$DIR_SH/$name" 0 \
        || { echo_log "下载 $name 失败"; exit 1; }
done
chmod +x "$DIR_SH"/*.sh

# === 第 3 步：按 OS 装服务文件 ===
echo_log ">>> 安装平台服务文件"
case "$OS_TYPE" in
    openwrt)
        # 代理内核 procd 服务
        download_file "$MP_REPO_RAW_URL/sh/etc/init.d/proxy_core" /etc/init.d/proxy_core 0 \
            || { echo_log "下载 init.d/proxy_core 失败"; exit 1; }
        # AdGuardHome procd 服务
        download_file "$MP_REPO_RAW_URL/sh/etc/init.d/agh" /etc/init.d/agh 0 \
            || { echo_log "下载 init.d/agh 失败"; exit 1; }
        # TUN 路由热插拔处理器
        download_file "$MP_REPO_RAW_URL/sh/etc/hotplug.d/net/99-meta-route" /etc/hotplug.d/net/99-meta-route 0 \
            || { echo_log "下载 99-meta-route 失败"; exit 1; }
        chmod +x /etc/init.d/proxy_core /etc/init.d/agh /etc/hotplug.d/net/99-meta-route
        ;;
    systemd)
        # 代理内核 systemd 单元
        download_file "$MP_REPO_RAW_URL/sh/etc/systemd/system/proxy_core.service" /etc/systemd/system/proxy_core.service 0 \
            || { echo_log "下载 proxy_core.service 失败"; exit 1; }
        # AdGuardHome systemd 单元
        download_file "$MP_REPO_RAW_URL/sh/etc/systemd/system/agh.service" /etc/systemd/system/agh.service 0 \
            || { echo_log "下载 agh.service 失败"; exit 1; }
        # 让 systemd 重新加载 unit 列表
        systemctl daemon-reload
        ;;
esac

# === 第 4 步：刷新配置（子脚本继承 MP_AUTOUPDATE=false，不会再触发自更新） ===
echo_log ">>> 刷新 AGH dns.conf 与 core/config.yaml"
sh "$DIR_SH/update-all-configs.sh" || echo_log "（部分步骤失败，详见上方日志）"

# === 第 5 步：启用并启动服务（任一步失败仅警告，不中断 inst） ===
echo_log ">>> 启用并启动服务"
case "$OS_TYPE" in
    openwrt)
        service proxy_core enable && service proxy_core start || echo_log "proxy_core 启动失败"
        service agh enable && service agh start || echo_log "agh 启动失败"
        ;;
    systemd)
        systemctl enable --now proxy_core.service || echo_log "proxy_core 启动失败"
        systemctl enable --now agh.service || echo_log "agh 启动失败"
        ;;
esac

# === 完成提示 ===
echo
echo "============ 安装完成 ============"
echo "  脚本目录：$DIR_SH"
echo "  首次部署在 $DIR_SH/env.local.conf 写入敏感参数后重跑："
echo "    MP_SUBSCRIBE_URL=https://...&url=<URL-encoded>"
echo "    sh $DIR_SH/update-all-configs-restart-services.sh"
case "$OS_TYPE" in
    openwrt) echo "  日志：logread -e MyProxy -f" ;;
    systemd) echo "  日志：journalctl -t MyProxy -f" ;;
esac
