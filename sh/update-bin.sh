#!/bin/sh
# 按 CPU 架构下载 mihomo 与 AdGuardHome 最新版到 $MP_CORE_DIR/$MP_AGH_DIR。
# 每次执行都覆盖现有二进制，不做版本对比；inst.sh 安装时调用，也可单独跑做升级。
# 单跑升级用法：
#   sh /etc/proxy/sh/update-bin.sh
#   sh /etc/proxy/sh/update-bin.sh && systemctl restart proxy_core agh   # 升级后需重启
. "$(dirname "$(readlink -f "$0")")/common.sh"

mkdir -p "$MP_CORE_DIR" "$MP_AGH_DIR"

echo_log "更新内核二进制（CPU: linux-$(uname -m)）"
case "$(uname -m)" in
    x86_64)         mihomo_arch=amd64;            agh_arch=amd64 ;;
    aarch64)        mihomo_arch=arm64;            agh_arch=arm64 ;;
    armv7l)         mihomo_arch=armv7;            agh_arch=armv7 ;;
    armv6l)         mihomo_arch=armv6;            agh_arch=armv6 ;;
    armv5*)         mihomo_arch=armv5;            agh_arch=armv5 ;;
    i386|i686)      mihomo_arch=386;              agh_arch=386 ;;
    mips)           mihomo_arch=mips-softfloat;   agh_arch=mips_softfloat ;;
    mipsel)         mihomo_arch=mipsle-softfloat; agh_arch=mipsle_softfloat ;;
    mips64)         mihomo_arch=mips64;           agh_arch=mips64 ;;
    mips64el)       mihomo_arch=mips64le;         agh_arch=mips64le ;;
    riscv64)        mihomo_arch=riscv64;          agh_arch= ;;
    *) mihomo_arch=; agh_arch= ;;
esac
[ -z "$mihomo_arch$agh_arch" ] && { echo_log "未识别架构 $(uname -m)，跳过"; exit 1; }

rc=0

# mihomo：版本号在文件名里，先从 /releases/latest 的 Location 头取最新版本
if [ -n "$mihomo_arch" ]; then
    ver=$(curl -sI --connect-timeout 10 --max-time 30 \
            https://github.com/MetaCubeX/mihomo/releases/latest \
          | sed -n 's|.*[Ll]ocation:[[:space:]]*.*tag/\([^[:space:]]*\).*|\1|p' \
          | head -1 | tr -d '\r')
    if [ -n "$ver" ]; then
        gz=$(mktemp)
        url="https://github.com/MetaCubeX/mihomo/releases/download/$ver/mihomo-linux-$mihomo_arch-$ver.gz"
        if download_file "$url" "$gz" true 0 \
           && gunzip -c "$gz" > "$MP_CORE_DIR/mihomo.tmp" \
           && [ -s "$MP_CORE_DIR/mihomo.tmp" ]; then
            mv "$MP_CORE_DIR/mihomo.tmp" "$MP_CORE_DIR/mihomo"
            chmod +x "$MP_CORE_DIR/mihomo"
            echo_log "mihomo $ver / linux-$mihomo_arch 已就位：$MP_CORE_DIR/mihomo"
        else
            echo_log "mihomo 下载或解压失败"
            rm -f "$MP_CORE_DIR/mihomo.tmp"
            rc=$((rc+1))
        fi
        rm -f "$gz"
    else
        echo_log "获取 mihomo 最新版本失败"
        rc=$((rc+1))
    fi
fi

# metacubexd UI：mihomo 的 Web 控制面板。架构无关的静态站点；
# core/config.yaml 里 external-ui: ui 已指向 $MP_CORE_DIR/ui
# tarball 内容直接在顶层（./index.html ./_nuxt/...），没有 dist/ 包一层；
# 故解压到子目录避免和 ui.tgz 同位
ui_tmp=$(mktemp -d); mkdir -p "$ui_tmp/extract"
ui_url="https://github.com/MetaCubeX/metacubexd/releases/latest/download/compressed-dist.tgz"
if download_file "$ui_url" "$ui_tmp/ui.tgz" true 0 \
   && tar -xzf "$ui_tmp/ui.tgz" -C "$ui_tmp/extract" 2>/dev/null \
   && [ -f "$ui_tmp/extract/index.html" ]; then
    rm -rf "$MP_CORE_DIR/ui"
    mkdir -p "$MP_CORE_DIR/ui"
    cp -rf "$ui_tmp/extract/." "$MP_CORE_DIR/ui/"
    echo_log "metacubexd UI 已就位：$MP_CORE_DIR/ui"
else
    echo_log "metacubexd UI 下载或解压失败"
    rc=$((rc+1))
fi
rm -rf "$ui_tmp"

# AdGuardHome：/releases/latest/download/ 直接给到最新 tar.gz
if [ -n "$agh_arch" ]; then
    tmp=$(mktemp -d)
    url="https://github.com/AdguardTeam/AdGuardHome/releases/latest/download/AdGuardHome_linux_${agh_arch}.tar.gz"
    if download_file "$url" "$tmp/agh.tar.gz" true 0 \
       && tar -xzf "$tmp/agh.tar.gz" -C "$tmp" \
       && [ -x "$tmp/AdGuardHome/AdGuardHome" ]; then
        mv "$tmp/AdGuardHome/AdGuardHome" "$MP_AGH_DIR/AdGuardHome"
        chmod +x "$MP_AGH_DIR/AdGuardHome"
        echo_log "AdGuardHome / linux-$agh_arch 已就位：$MP_AGH_DIR/AdGuardHome"
    else
        echo_log "AdGuardHome 下载或解压失败"
        rc=$((rc+1))
    fi
    rm -rf "$tmp"
fi

exit "$rc"
