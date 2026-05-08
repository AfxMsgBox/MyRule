#!/bin/sh
# MyProxy 一键安装：下载所有脚本与服务文件，刷新配置，启用并启动服务。
# 前提：本机已按默认路径装好 mihomo（/etc/proxy/core/mihomo）
#       与 AdGuardHome（/usr/bin/AdGuardHome）；如不一致请改 env.local.conf。
#
# 用法（OpenWrt 与 Debian/Ubuntu 通用，需 root）：
#   wget -O- https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/inst.sh | sh
# 自托管仓库可：
#   MP_REPO_RAW_URL=https://my.fork.example/raw \
#       wget -O- https://my.fork.example/raw/sh/inst.sh | sh

# 必须 root 才能写 /etc/init.d、/etc/systemd/system、/etc/proxy 等
[ "$(id -u)" = "0" ] || { echo "需要 root 权限运行（Debian/Ubuntu 请加 sudo）" >&2; exit 1; }

# 仓库 raw 根；inst 是引导阶段，env.conf 还没下来，唯一允许在脚本里硬编码这个常量的地方
MP_REPO_RAW_URL="${MP_REPO_RAW_URL:-https://raw.githubusercontent.com/AfxMsgBox/MyRule/main}"
# 脚本安装目标目录
DIR_SH="${DIR_SH:-/etc/proxy/sh}"

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

# 加载 env + 公共函数；不设 url_self，common.sh 会自动跳过自更新
# shellcheck disable=SC1091
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

# === 第 4 步：刷新配置（缺 local.conf 时 update-core-config.sh 会优雅跳过） ===
echo_log ">>> 刷新 AGH dns.conf 与 core/config.yaml"
sh "$DIR_SH/update-all-configs.sh" --noupdate || echo_log "（部分步骤失败，详见上方日志）"

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
echo "  本地覆盖：$DIR_SH/env.local.conf（按需创建）"
echo "  内核敏感参数：\$MP_CORE_DIR/local.conf（默认 /etc/proxy/core/local.conf）"
echo "                 首次部署需要写入订阅 URL 与节点参数后重跑："
echo "                 sh $DIR_SH/update-all-configs-restart-services.sh"
case "$OS_TYPE" in
    openwrt) echo "  日志：logread -e MyProxy -f" ;;
    systemd) echo "  日志：journalctl -t MyProxy -f" ;;
esac
