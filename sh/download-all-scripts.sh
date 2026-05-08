#!/bin/sh
# 首次安装 / 全量重装：把仓库脚本与对应平台的服务文件下到本地。
# 自动识别 OpenWrt（procd + hotplug）与 systemd（Debian/Ubuntu）。
#
# 注意：这是 bootstrap 阶段，env.conf 尚未下载，所以本脚本是唯一允许
# 在脚本内部硬编码 MP_REPO_RAW_URL 默认值的地方；其它脚本一律通过
# env.conf 拿到这些常量。可通过环境变量覆盖：
#   MP_REPO_RAW_URL=https://my.fork.example/raw sh download-all-scripts.sh

set -e

# 本脚本所在目录（公共脚本都装到这里）
dir_self=$(dirname "$(readlink -f "$0")")
# 仓库 raw 根 URL；可通过环境变量覆盖
MP_REPO_RAW_URL="${MP_REPO_RAW_URL:-https://raw.githubusercontent.com/AfxMsgBox/MyRule/main}"

# 识别 OS：openwrt | systemd | unknown，可通过 OS_TYPE 环境变量强制
if [ -n "$OS_TYPE" ]; then
    :
elif [ -f /etc/openwrt_release ] || grep -qs '^ID=.*openwrt' /etc/os-release; then
    OS_TYPE=openwrt
elif command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ]; then
    OS_TYPE=systemd
else
    OS_TYPE=unknown
fi
echo "目标系统：$OS_TYPE"

# 简易下载：失败时再试一次（首次安装时本地代理通常未起）
fetch() {
    mkdir -p "$(dirname "$2")"
    wget -q -O "$2" "$1" || { echo "下载失败重试：$1" >&2; wget -O "$2" "$1"; }
}

# 仓库内 sh/ 下的公共脚本（两个平台都装）
for name in env.conf common.sh keeplive.sh setup-fake-ip-route.sh \
            update-agh-config.sh update-all-configs.sh \
            update-all-configs-restart-services.sh \
            update-core-config.sh update-proxy-rule.sh \
            download-all-scripts.sh inst.sh; do
    fetch "$MP_REPO_RAW_URL/sh/$name" "$dir_self/$name"
done
# 全部加可执行权限
chmod +x "$dir_self"/*.sh

# 按 OS 分发服务文件
case "$OS_TYPE" in
    openwrt)
        # 代理内核 procd 服务
        fetch "$MP_REPO_RAW_URL/sh/etc/init.d/proxy_core" /etc/init.d/proxy_core
        # AdGuardHome procd 服务
        fetch "$MP_REPO_RAW_URL/sh/etc/init.d/agh" /etc/init.d/agh
        # TUN 接口路由热插拔处理器
        fetch "$MP_REPO_RAW_URL/sh/etc/hotplug.d/net/99-meta-route" /etc/hotplug.d/net/99-meta-route
        # 加可执行权限
        chmod +x /etc/init.d/proxy_core /etc/init.d/agh /etc/hotplug.d/net/99-meta-route
        echo "已装到 /etc/init.d/{proxy_core,agh}、/etc/hotplug.d/net/99-meta-route"
        echo "启动：service proxy_core enable && service proxy_core start"
        echo "      service agh enable && service agh start"
        ;;
    systemd)
        # 代理内核 systemd 单元
        fetch "$MP_REPO_RAW_URL/sh/etc/systemd/system/proxy_core.service" /etc/systemd/system/proxy_core.service
        # AdGuardHome systemd 单元
        fetch "$MP_REPO_RAW_URL/sh/etc/systemd/system/agh.service" /etc/systemd/system/agh.service
        # 让 systemd 重新加载 unit 列表
        systemctl daemon-reload
        echo "已装到 /etc/systemd/system/{proxy_core,agh}.service"
        echo "启动：systemctl enable --now proxy_core.service"
        echo "      systemctl enable --now agh.service"
        ;;
    *)
        echo "未识别的系统；用 OS_TYPE=openwrt 或 OS_TYPE=systemd 强制：" >&2
        echo "  OS_TYPE=systemd sh $dir_self/download-all-scripts.sh" >&2
        ;;
esac

echo
echo "下一步："
echo "  1. 编辑 $dir_self/env.local.conf（可选，覆盖 env.conf 中的 MP_* 默认值）"
echo "  2. 编辑 \$MP_CORE_DIR/local.conf（默认 /etc/proxy/core/local.conf）写入订阅 URL 等"
echo "  3. 运行 sh $dir_self/update-all-configs.sh"
