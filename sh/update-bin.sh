#!/bin/sh
# 按 CPU 架构下载 mihomo 与 AdGuardHome 最新版到 $MP_CORE_DIR/$MP_AGH_DIR。
# 每次执行都覆盖现有二进制，不做版本对比；inst.sh 安装时调用，也可单独跑做升级。
# 单跑升级用法：
#   sh /etc/proxy/sh/update-bin.sh
#   sh /etc/proxy/sh/update-bin.sh && systemctl restart proxy_core agh   # 升级后需重启
. "$(dirname "$(readlink -f "$0" 2>/dev/null || printf '%s\n' "$0")")/common.sh"

# 安装时传入 pending Core 配置，仅用于确定 UI 路径；下载仍使用正式配置的代理。
core_config="${1:-$MP_CORE_DIR/config.yaml}"
mkdir -p "$MP_CORE_DIR" "$MP_AGH_DIR" || exit 1

binary_arch=${_MP_TARGET_ARCH:-$(uname -m)}
echo_log "更新内核二进制（CPU: linux-$binary_arch）"
case "$binary_arch" in
    x86_64)         mihomo_arch=amd64-compatible; agh_arch=amd64 ;;
    aarch64)        mihomo_arch=arm64;            agh_arch=arm64 ;;
    armv7l)         mihomo_arch=armv7;            agh_arch=armv7 ;;
    armv6l)         mihomo_arch=armv6;            agh_arch=armv6 ;;
    armv5*)         mihomo_arch=armv5;            agh_arch=armv5 ;;
    i386|i686)      mihomo_arch=386;              agh_arch=386 ;;
    mips)           mihomo_arch=mips-softfloat;   agh_arch=mips_softfloat ;;
    mipsel)         mihomo_arch=mipsle-softfloat; agh_arch=mipsle_softfloat ;;
    mips64)         mihomo_arch=mips64;           agh_arch=mips64 ;;
    mips64el)       mihomo_arch=mips64le;         agh_arch=mips64le ;;
    *) mihomo_arch=; agh_arch= ;;
esac
[ -z "$mihomo_arch$agh_arch" ] && { echo_log "未识别架构 $binary_arch，跳过"; exit 1; }

# 所有组件均为必需资源；失败立即结束，临时文件统一清理。
bin_work=$(mktemp -d) || exit 1
trap 'rm -rf -- "$bin_work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

release_meta="$bin_work/mihomo-release.json"
download_file 'https://api.github.com/repos/MetaCubeX/mihomo/releases/latest' \
    "$release_meta" true 8 'Mihomo 最新版本信息' 60 || exit 1
ver=$(jq -er '.tag_name | select(type == "string" and length > 0 and
    (explode - ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-" | explode) | length == 0))' "$release_meta" 2>/dev/null) \
    || { echo_log 'Mihomo 版本响应格式错误或缺少有效 tag_name'; exit 1; }
url="https://github.com/MetaCubeX/mihomo/releases/download/$ver/mihomo-linux-$mihomo_arch-$ver.gz"
if ! download_file "$url" "$bin_work/mihomo.gz" true 8 "Mihomo $ver / linux-$mihomo_arch" \
    || ! gunzip -c "$bin_work/mihomo.gz" > "$bin_work/mihomo" \
    || [ ! -s "$bin_work/mihomo" ] \
    || ! chmod 0755 "$bin_work/mihomo"; then
    echo_log 'mihomo 下载、解压或安装失败'; exit 1
fi
# prepare 只为目标收集资源，不能在 macOS/不同 CPU 的发起端执行 Linux 程序。
# apply 与日常更新在替换旧二进制前检查，保留原生诊断及实际退出码。
if [ -z "${_MP_CACHE_WRITE:-}" ]; then
    echo_log '检查 Mihomo 是否能在目标机运行'
    bin_check_rc=0
    mp_run_logged_command "$bin_work/mihomo" -v || bin_check_rc=$?
    if [ "$bin_check_rc" -ne 0 ]; then
        echo_log "Mihomo 无法在目标机运行（退出码 $bin_check_rc），请检查 CPU 指令集及系统兼容性；未替换现有内核"
        exit "$bin_check_rc"
    fi
fi
mp_install_binary "$bin_work/mihomo" "$MP_CORE_DIR/mihomo" \
    || { echo_log 'mihomo 安装失败'; exit 1; }
echo_log "mihomo $ver / linux-$mihomo_arch 已就位：$MP_CORE_DIR/mihomo"

core_ui_dir=$(mp_core_external_ui_path "$core_config" 2>/dev/null || :)
[ -n "$core_ui_dir" ] || { echo_log 'Core 配置缺少安全有效的 external-ui'; exit 1; }
ui_url='https://github.com/MetaCubeX/metacubexd/releases/latest/download/compressed-dist.tgz'
if ! mkdir "$bin_work/ui" \
    || ! download_file "$ui_url" "$bin_work/ui.tgz" true 8 'metacubexd 面板' \
    || ! tar -xzf "$bin_work/ui.tgz" -C "$bin_work/ui" 2>/dev/null \
    || [ ! -f "$bin_work/ui/index.html" ] \
    || ! mp_install_ui "$bin_work/ui" "$core_ui_dir"; then
    echo_log 'metacubexd UI 下载、解压或安装失败'; exit 1
fi
echo_log "metacubexd UI 已就位：$core_ui_dir"

url="https://github.com/AdguardTeam/AdGuardHome/releases/latest/download/AdGuardHome_linux_${agh_arch}.tar.gz"
if ! download_file "$url" "$bin_work/agh.tar.gz" true 8 "AdGuardHome / linux-$agh_arch" \
    || ! tar -xzf "$bin_work/agh.tar.gz" -C "$bin_work" 2>/dev/null \
    || [ ! -x "$bin_work/AdGuardHome/AdGuardHome" ] \
    || ! mp_install_binary "$bin_work/AdGuardHome/AdGuardHome" "$MP_AGH_DIR/AdGuardHome"; then
    echo_log 'AdGuardHome 下载、解压或安装失败'; exit 1
fi
echo_log "AdGuardHome / linux-$agh_arch 已就位：$MP_AGH_DIR/AdGuardHome"
