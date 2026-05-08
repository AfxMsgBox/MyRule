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

# 仓库 raw 根；可通过环境变量覆盖（其它脚本一律走 env.conf，inst 是引导阶段例外）
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

# 简易下载：失败时再试一次（首次安装时本地代理通常未起）
fetch() {
    mkdir -p "$(dirname "$2")"
    wget -q -O "$2" "$1" || { echo "下载失败重试：$1" >&2; wget -O "$2" "$1"; }
}

# === 第 1 步：下载公共脚本到 $DIR_SH ===
echo
echo ">>> 下载脚本到 $DIR_SH"
mkdir -p "$DIR_SH"
for name in env.conf common.sh keeplive.sh setup-fake-ip-route.sh \
            update-agh-config.sh update-all-configs.sh \
            update-all-configs-restart-services.sh \
            update-core-config.sh update-proxy-rule.sh inst.sh; do
    fetch "$MP_REPO_RAW_URL/sh/$name" "$DIR_SH/$name"
done
chmod +x "$DIR_SH"/*.sh

# === 第 2 步：按 OS 装服务文件 ===
echo
echo ">>> 安装平台服务文件"
case "$OS_TYPE" in
    openwrt)
        # 代理内核 procd 服务
        fetch "$MP_REPO_RAW_URL/sh/etc/init.d/proxy_core" /etc/init.d/proxy_core
        # AdGuardHome procd 服务
        fetch "$MP_REPO_RAW_URL/sh/etc/init.d/agh" /etc/init.d/agh
        # TUN 接口路由热插拔处理器
        fetch "$MP_REPO_RAW_URL/sh/etc/hotplug.d/net/99-meta-route" /etc/hotplug.d/net/99-meta-route
        chmod +x /etc/init.d/proxy_core /etc/init.d/agh /etc/hotplug.d/net/99-meta-route
        ;;
    systemd)
        # 代理内核 systemd 单元
        fetch "$MP_REPO_RAW_URL/sh/etc/systemd/system/proxy_core.service" /etc/systemd/system/proxy_core.service
        # AdGuardHome systemd 单元
        fetch "$MP_REPO_RAW_URL/sh/etc/systemd/system/agh.service" /etc/systemd/system/agh.service
        # 让 systemd 重新加载 unit 列表
        systemctl daemon-reload
        ;;
esac

# === 第 3 步：刷新配置（缺 local.conf 时 update-core-config.sh 会优雅跳过） ===
echo
echo ">>> 刷新 AGH dns.conf 与 core/config.yaml"
sh "$DIR_SH/update-all-configs.sh" --noupdate || echo "（部分步骤失败，详见上方日志）"

# === 第 4 步：启用并启动服务（任一步失败仅警告，不中断 inst） ===
echo
echo ">>> 启用并启动服务"
case "$OS_TYPE" in
    openwrt)
        service proxy_core enable && service proxy_core start || echo "proxy_core 启动失败"
        service agh enable && service agh start || echo "agh 启动失败"
        ;;
    systemd)
        systemctl enable --now proxy_core.service || echo "proxy_core 启动失败"
        systemctl enable --now agh.service || echo "agh 启动失败"
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
