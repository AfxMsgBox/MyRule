#!/bin/sh
# 唯一负责"更新脚本"的入口：
#   - env.conf / common.sh
#   - sh/ 下所有 *.sh（含本脚本自身、inst.sh、各 update-*.sh、keeplive 等）
#   - sh/etc/ 下所有服务/hotplug 文件（含路径占位替换）
#   - 若 /etc/{init.d,systemd/system,hotplug.d/net} 已存在对应文件（当初 inst 选了自启动），
#     则同步覆盖一份，systemd 自动 daemon-reload
#
# 其余 update-* 脚本（配置 / 二进制）不再做任何脚本自更新——更可控。
#
# 用法：
#   sh /etc/proxy/sh/update-scripts.sh
. "$(dirname "$(readlink -f "$0")")/common.sh"

dir_sh="$MP_INST_DIR/sh"
mkdir -p "$dir_sh/etc"

echo_log "============ update scripts ============"

# 1) env.conf + common.sh
rc=0
download_file "$MP_REPO_RAW_URL/sh/env.conf"  "$dir_sh/env.conf"  || { echo_log "env.conf 更新失败";  rc=$((rc+1)); }
download_file "$MP_REPO_RAW_URL/sh/common.sh" "$dir_sh/common.sh" || { echo_log "common.sh 更新失败"; rc=$((rc+1)); }

# 2) sh/*.sh（含 inst.sh、本脚本自身）
for name in inst.sh keeplive.sh setup-fake-ip-route.sh \
            update-scripts.sh update-bin.sh \
            update-all-configs.sh update-all-configs-restart-services.sh \
            update-agh-config.sh update-core-config.sh update-proxy-rule.sh; do
    if download_file "$MP_REPO_RAW_URL/sh/$name" "$dir_sh/$name"; then
        chmod +x "$dir_sh/$name"
    else
        echo_log "$name 更新失败"; rc=$((rc+1))
    fi
done

# 3) sh/etc/* 服务文件：先按 OS 选清单，下载到本地后 sed 替换路径占位
mp_detect_os || { echo_log "未识别 OS，跳过 sh/etc 更新"; exit "$rc"; }
case "$MP_OS_TYPE" in
    openwrt) etc_rels="init.d/proxy_core init.d/agh hotplug.d/net/99-meta-route" ;;
    systemd) etc_rels="systemd/system/proxy_core.service systemd/system/agh.service" ;;
esac

systemd_changed=0
for rel in $etc_rels; do
    local_path="$dir_sh/etc/$rel"
    mkdir -p "$(dirname "$local_path")"
    if ! download_file "$MP_REPO_RAW_URL/sh/etc/$rel" "$local_path"; then
        echo_log "$rel 更新失败"; rc=$((rc+1)); continue
    fi
    sed -i "s|/etc/proxy|$MP_INST_DIR|g" "$local_path"
    chmod +x "$local_path" 2>/dev/null || true
    # 当初 inst 选了自启动，/etc 下有对应文件 → 同步覆盖
    if [ -e "/etc/$rel" ]; then
        cp "$local_path" "/etc/$rel" && chmod +x "/etc/$rel" 2>/dev/null
        echo_log "同步 /etc/$rel"
        [ "$MP_OS_TYPE" = "systemd" ] && systemd_changed=1
    fi
done

[ "$systemd_changed" = "1" ] && systemctl daemon-reload

[ "$rc" -eq 0 ] && echo_log "============ scripts done ============" \
                || echo_log "============ scripts done with errors (rc=$rc) ============"
exit "$rc"
