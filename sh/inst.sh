#!/bin/sh
# MyProxy 一键安装：下载所有脚本与服务文件，刷新配置，启用并启动服务。
# 前提：本机已装好 mihomo 与 AdGuardHome；路径与默认不同时在 env.local.conf
#       用 MP_CORE_BIN / MP_AGH_BIN 覆盖。
#
# 用法（需 root；安装目录作为第一个参数，省略则用 $PWD 作为 sh 目录，
# core / agh 会被推导为 sh 的兄弟目录）：
#   mkdir -p /opt/myproxy/sh && cd $_ && sh inst.sh   # 装到 /opt/myproxy/{sh,core,agh}
#   sh inst.sh /etc/proxy/sh                           # 显式指定，装到 /etc/proxy/{sh,core,agh}
# wget|sh 管道时用 sh -s -- 传位置参数：
#   wget -O- https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/inst.sh | sh -s -- /etc/proxy/sh
# 自托管 / 分支调试：
#   MP_REPO_RAW_URL=https://raw.githubusercontent.com/AfxMsgBox/MyRule/refs/heads/<branch> \
#       wget -O- "$MP_REPO_RAW_URL/sh/inst.sh" | sh

# 必须 root 才能写 /etc/init.d、/etc/systemd/system 等
[ "$(id -u)" = "0" ] || { echo "需要 root 权限运行（Debian/Ubuntu 请加 sudo）" >&2; exit 1; }

# 安装目录：第一个位置参数 > 默认当前目录（$PWD 作为 sh 目录）
# 不给参数时，建议先 cd 到一个有意义的位置（如 mkdir -p /opt/myproxy/sh && cd $_）
DIR_SH="${1:-$PWD}"

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
# 显式声明安装目录：inst.sh 本身可能在 /tmp 或经 wget|sh 运行（$0 不可靠），
# 必须在 source common.sh 前把 MP_SH_DIR 定死为 DIR_SH，否则 common.sh 会
# 按 inst.sh 的 $0 推导出错误目录并 export 给所有子脚本
export MP_SH_DIR="$DIR_SH"
# 加载 env + 公共函数；不设 url_self，common.sh 自动跳过自更新
. "$DIR_SH/common.sh"

# === 第 2 步：用 download_file 拉其它公共脚本（享受代理回退 / --fail / 重试） ===
echo_log ">>> 下载脚本到 $DIR_SH"
for name in keeplive.sh setup-fake-ip-route.sh \
            update-agh-config.sh update-all-configs.sh \
            update-all-configs-restart-services.sh \
            update-core-config.sh update-proxy-rule.sh inst.sh; do
    download_file "$MP_REPO_RAW_URL/sh/$name" "$DIR_SH/$name" true 0 \
        || { echo_log "下载 $name 失败"; exit 1; }
done
chmod +x "$DIR_SH"/*.sh

# === 第 3 步：按 OS 装服务文件 ===
# 仓库里的服务文件用 /etc/proxy/sh 占位，装到 $DIR_SH 时统一 sed 替换
echo_log ">>> 安装平台服务文件"
patch_paths() { sed -i "s|/etc/proxy/sh|$DIR_SH|g" "$1"; }
case "$OS_TYPE" in
    openwrt)
        for f in init.d/proxy_core init.d/agh hotplug.d/net/99-meta-route; do
            download_file "$MP_REPO_RAW_URL/sh/etc/$f" "/etc/$f" true 0 \
                || { echo_log "下载 $f 失败"; exit 1; }
            patch_paths "/etc/$f"
            chmod +x "/etc/$f"
        done
        ;;
    systemd)
        for f in proxy_core.service agh.service; do
            download_file "$MP_REPO_RAW_URL/sh/etc/systemd/system/$f" "/etc/systemd/system/$f" true 0 \
                || { echo_log "下载 $f 失败"; exit 1; }
            patch_paths "/etc/systemd/system/$f"
        done
        systemctl daemon-reload
        ;;
esac

# === 第 4 步：刷新配置 ===
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

# === 完成：把安装目录与仓库分支写入 env.local.conf（不动 env.conf） ===
# upsert_conf <key> <value> <file>：已存在则替换，否则追加
upsert_conf() {
    if grep -q "^$1=" "$3" 2>/dev/null; then
        sed -i "s|^$1=.*|$1=\"$2\"|" "$3"
    else
        echo "$1=\"$2\"" >> "$3"
    fi
}
upsert_conf MP_SH_DIR       "$DIR_SH"          "$DIR_SH/env.local.conf"
upsert_conf MP_REPO_RAW_URL "$MP_REPO_RAW_URL"  "$DIR_SH/env.local.conf"

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
