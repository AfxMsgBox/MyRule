#!/bin/sh
# 临时升级兼容：旧安装退出支持后，删除本脚本及 mp_sync_etc_files 中的调用。
. "$(dirname "$(readlink -f "$0" 2>/dev/null || printf '%s\n' "$0")")/common.sh" || exit 1

# 旧 hotplug -> Netlink 的迁移清理。
# 99-meta-route 是本项目保留名称；只清理下列两个固定路径。
mp_migrate_legacy_routes() {
    for _mlrh_file in "$MP_INST_DIR/sh/etc/hotplug.d/net/99-meta-route" \
        /etc/hotplug.d/net/99-meta-route; do
        [ -e "$_mlrh_file" ] || [ -L "$_mlrh_file" ] || continue
        # 用户指定：按保留文件名清理，不再检查历史文件内容；不跟随符号链接。
        rm -f -- "$_mlrh_file" || {
            echo_log "无法删除旧 hotplug：${_mlrh_file}；请检查权限或同名目录"; return 1;
        }
        echo_log "已清理旧路由 hotplug：$_mlrh_file"
    done
}

# 仅移除旧安装拥有的独立路由服务与启动脚本。
mp_migrate_legacy_core() {
    _mlc_unit="/etc/systemd/system/proxy_route.service"
    if [ -e "$_mlc_unit" ] || [ -L "$_mlc_unit" ]; then
        # 历史 unit 通过 sh -c 设置安装目录，脚本路径中的变量并未展开。
        # 比较完整 ExecStart，同时核对目录赋值，不能只匹配变量路径。
        _mlc_direct="ExecStart=/bin/sh $MP_INST_DIR/sh/setup-fake-ip-route.sh --watch"
        _mlc_shell="ExecStart=/bin/sh -c 'MP_INST_DIR=$MP_INST_DIR; export MP_INST_DIR; exec /bin/sh \"\$MP_INST_DIR/sh/setup-fake-ip-route.sh\" --watch'"
        [ ! -L "$_mlc_unit" ] && [ -f "$_mlc_unit" ] \
            && grep -qxF 'Documentation=https://github.com/AfxMsgBox/MyRule' "$_mlc_unit" \
            && grep -qxF -e "$_mlc_direct" -e "$_mlc_shell" "$_mlc_unit" \
            || { echo_log '旧 route 服务归属不匹配，停止迁移'; return 1; }
        systemctl stop proxy_route.service || return 1
        for _mlc_link in /etc/systemd/system/*.wants/proxy_route.service /etc/systemd/system/*.requires/proxy_route.service; do
            [ -L "$_mlc_link" ] || continue
            case "$(readlink "$_mlc_link")" in ../proxy_route.service|/etc/systemd/system/proxy_route.service) rm -f "$_mlc_link" || return 1 ;;
                *) echo_log '旧 route 服务链接归属不匹配'; return 1 ;;
            esac
        done
        rm -f "$_mlc_unit" || return 1
    fi
    _mlc_old="$MP_INST_DIR/sh/setup-fake-ip-route.sh"
    if [ -e "$_mlc_old" ] || [ -L "$_mlc_old" ]; then
        [ ! -L "$_mlc_old" ] && grep -Eq 'route_watch\(\)|^# (auto-route:false|修复 mihomo TUN 路由)' "$_mlc_old" \
            || { echo_log '旧路由脚本归属不匹配'; return 1; }
        rm -f "$_mlc_old" || return 1
    fi
    # 旧模板副本可能由用户修改，只删除带项目标记的普通文件。
    for _mlc_file in "$MP_INST_DIR"/sh/etc/systemd/system/*.service "$MP_INST_DIR"/sh/etc/init.d/agh "$MP_INST_DIR"/sh/etc/init.d/proxy_core; do
        [ -e "$_mlc_file" ] || [ -L "$_mlc_file" ] || continue
        [ ! -L "$_mlc_file" ] && { grep -qF 'Documentation=https://github.com/AfxMsgBox/MyRule' "$_mlc_file" \
            || { grep -qF 'USE_PROCD=1' "$_mlc_file" && grep -qF "MP_INST_DIR=$MP_INST_DIR" "$_mlc_file"; }; } \
            || { echo_log '旧服务模板归属不匹配'; return 1; }
        rm -f "$_mlc_file" || return 1
    done
    for _mlc_dir in "$MP_INST_DIR/sh/etc/systemd/system" "$MP_INST_DIR/sh/etc/systemd" \
        "$MP_INST_DIR/sh/etc/init.d" "$MP_INST_DIR/sh/etc/hotplug.d/net" "$MP_INST_DIR/sh/etc/hotplug.d" "$MP_INST_DIR/sh/etc"; do
        [ ! -d "$_mlc_dir" ] || rmdir "$_mlc_dir" 2>/dev/null || :
    done
}


mp_migrate_legacy_proxy() {
    _mlp_file="$MP_INST_DIR/sh/env.local.conf"
    [ -f "$_mlp_file" ] || return 0
    [ ! -L "$_mlp_file" ] || { echo_log '本机配置不能是符号链接'; return 1; }
    grep -Eq '^[[:space:]]*(export[[:space:]]+)?MP_PROXY=' "$_mlp_file" || return 0
    _mlp_tmp=$(mktemp "$MP_INST_DIR/sh/.env-migrate.XXXXXX") || return 1
    if awk '!/^[[:space:]]*(export[[:space:]]+)?MP_PROXY=/' "$_mlp_file" > "$_mlp_tmp" \
        && chmod 600 "$_mlp_tmp" && mv "$_mlp_tmp" "$_mlp_file"; then
        echo_log '已移除废弃的外部下载代理配置'
    else
        rm -f "$_mlp_tmp"; return 1
    fi
}

mp_migrate_legacy_routes && mp_migrate_legacy_core && mp_migrate_legacy_proxy
