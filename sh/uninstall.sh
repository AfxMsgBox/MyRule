#!/bin/sh
# 独立卸载入口：不加载 env.local.conf、不联网，不依赖待删除目录中的公共函数。

un_log() { printf '%s\n' "$*"; }
un_fail() { un_log "[失败] $*" >&2; return 1; }

un_usage() {
    cat <<'USAGE'
用法：sh uninstall.sh [--install-dir DIR] [--purge] [--yes]
  --install-dir DIR   安装目录，默认 /etc/proxy（绝对路径）
  --purge             删除该目录内的 sh/、core/、agh/，包括配置和运行数据
  --yes               跳过交互确认；不跳过归属和安全检查
  --help              显示帮助
默认仅移除服务、自启动、hotplug 和安装器创建的定时任务，保留安装目录。
始终保留 IPv4 转发设置及用户手工配置的其它任务。
USAGE
}

un_parse() {
    un_dir=/etc/proxy; un_purge=0; un_yes=0; un_help=0; un_seen=' '
    if [ "$#" -eq 1 ] && [ "$1" = --help ]; then un_help=1; return 0; fi
    while [ "$#" -gt 0 ]; do
        un_key=${1%%=*}
        case "$un_seen" in *" $un_key "*) un_fail "重复参数：$un_key"; return 1 ;; esac
        un_seen="$un_seen$un_key "
        case "$1" in
            --yes) un_yes=1; shift ;;
            --purge) un_purge=1; shift ;;
            --install-dir=*) un_dir=${1#*=}; shift ;;
            --install-dir)
                [ "$#" -ge 2 ] || { un_fail '--install-dir 缺少值'; return 1; }
                un_dir=$2; shift 2 ;;
            *) un_fail '未知参数，请使用 --help'; return 1 ;;
        esac
    done
}

un_check_dir() {
    case "$un_dir" in /*) ;; *) un_fail '安装目录必须为绝对路径'; return 1 ;; esac
    case "$un_dir" in *[!a-zA-Z0-9_./-]*|*/../*|*/..|*/./*|*/.)
        un_fail '安装目录含不支持的字符或路径跳转'; return 1 ;;
    esac
    # 安装器采用固定路径文本；只消除尾斜杠，不执行配置文件。
    while [ "${un_dir%/}" != "$un_dir" ]; do un_dir=${un_dir%/}; done
    case "$un_dir" in ''|*//*) un_fail '无效安装目录'; return 1 ;; esac
    un_real=$(readlink -f "$un_dir") || { un_fail '无法解析安装目录'; return 1; }
    case "$un_real" in *[!a-zA-Z0-9_./-]*) un_fail '物理安装路径含不支持的字符'; return 1 ;; esac
    case "$un_real" in /|/etc|/usr|/usr/local|/var|/var/lib|/var/log|/opt|/tmp|/home|/root|/srv|/bin|/sbin|/lib|/lib64|/boot|/dev|/proc|/sys|/run|/mnt|/media)
        un_fail '拒绝将系统目录作为卸载目标'; return 1 ;;
    esac
    [ ! -e "$un_dir" ] || [ -d "$un_dir" ] || { un_fail '安装目录不是目录'; return 1; }
    [ "$un_purge" -eq 1 ] || return 0
    un_has_data=0
    for un_part in sh core agh; do
        [ ! -L "$un_dir/$un_part" ] || { un_fail "拒绝删除符号链接目录：$un_part"; return 1; }
        [ ! -e "$un_dir/$un_part" ] || un_has_data=1
    done
    [ "$un_has_data" -eq 1 ] || return 0
    # 本机配置作为安装凭据，只匹配赋值文本，禁止 source（其中可能含任意 shell 命令）。
    [ -f "$un_dir/sh/env.local.conf" ] && [ ! -L "$un_dir/sh/env.local.conf" ] \
        || { un_fail '缺少本机安装配置，拒绝删除数据'; return 1; }
    awk -v dir="$un_dir" '
        { sub(/^[ \t]*(export[ \t]+)?/, "") }
        $0 == "MP_INST_DIR=" dir || $0 == "MP_INST_DIR=\047" dir "\047" ||
        $0 == "MP_INST_DIR=\042" dir "\042" { found=1 }
        END { exit !found }
    ' "$un_dir/sh/env.local.conf" || { un_fail '本机配置的安装目录不匹配，拒绝删除数据'; return 1; }
    # rm -r 不能跨入安装数据中的挂载点，包括绑定挂载。
    [ -r "$un_proc/self/mountinfo" ] || { un_fail '无法检查挂载点，拒绝删除数据'; return 1; }
    awk -v dir="$un_real" '
        { for (i=1;i<=3;i++) {
            part=(i==1 ? "sh" : (i==2 ? "core" : "agh")); base=dir "/" part
            if ($5==base || index($5,base "/")==1) bad=1
        } }
        END { exit bad }
    ' "$un_proc/self/mountinfo" || { un_fail '安装数据内存在挂载点，请先处理后重试'; return 1; }
}

# 存在但不属于目标安装的同名文件导致整次预检失败，不能停止它的服务。
un_check_file() {
    un_cf_path=$1; un_cf_kind=$2
    [ -e "$un_cf_path" ] || [ -L "$un_cf_path" ] || return 0
    [ -f "$un_cf_path" ] && [ ! -L "$un_cf_path" ] \
        || { un_fail "无法确认文件归属：$un_cf_path"; return 1; }
    case "$un_cf_kind" in
        unit)
            grep -qxF 'Documentation=https://github.com/AfxMsgBox/MyRule' "$un_cf_path" \
                && awk -v dir="$un_dir" 'index($0,"ExecStart=")==1 && index($0,"MP_INST_DIR=" dir ";") { ok=1 }
                    END { exit !ok }' "$un_cf_path" ;;
        init)
            grep -qxF "MP_INST_DIR=$un_dir" "$un_cf_path" \
                && grep -qxF '. "$MP_INST_DIR/sh/env.conf"' "$un_cf_path" \
                && grep -qxF 'USE_PROCD=1' "$un_cf_path" ;;
        hotplug) grep -qxF "exec $un_dir/sh/setup-fake-ip-route.sh" "$un_cf_path" ;;
    esac || { un_fail "文件不属于目标安装：$un_cf_path"; return 1; }
    printf '%s\n' "$un_cf_path" >> "$un_tmp/files"
}

un_check_link() {
    un_cl_link=$1; un_cl_target=$2
    [ -e "$un_cl_link" ] || [ -L "$un_cl_link" ] || return 0
    [ -L "$un_cl_link" ] && [ "$(readlink -f "$un_cl_link")" = "$un_cl_target" ] \
        || { un_fail "自启动项归属不匹配：$un_cl_link"; return 1; }
    printf '%s\n' "$un_cl_link" >> "$un_tmp/links"
}

un_preflight_services() {
    : > "$un_tmp/files" && : > "$un_tmp/links" && : > "$un_tmp/services" || return 1
    for un_svc in agh proxy_core; do
        un_unit="$un_etc/systemd/system/$un_svc.service"
        un_init="$un_etc/init.d/$un_svc"
        un_check_file "$un_unit" unit && un_check_file "$un_init" init || return 1
        for un_link in "$un_etc"/systemd/system/*.wants/"$un_svc.service" \
            "$un_etc"/systemd/system/*.requires/"$un_svc.service"; do
            un_check_link "$un_link" "$un_unit" || return 1
        done
        for un_link in "$un_etc"/rc.d/[SK][0-9][0-9]"$un_svc" \
            "$un_etc"/rc[0-6S].d/[SK][0-9][0-9]"$un_svc"; do
            un_check_link "$un_link" "$un_init" || return 1
        done
        if [ "$un_os" = systemd ]; then
            un_show_rc=0
            un_info=$(systemctl show --property=LoadState --property=FragmentPath --property=DropInPaths "$un_svc.service") \
                || un_show_rc=$?
            un_state=$(printf '%s\n' "$un_info" | sed -n 's/^LoadState=//p')
            [ "$un_show_rc" -eq 0 ] || [ "$un_state" = not-found ] \
                || { un_fail "无法查询 $un_svc 服务归属"; return 1; }
            case "$un_state" in loaded|not-found) ;; *) un_fail "$un_svc 服务状态无法确认"; return 1 ;; esac
            un_fragment=$(printf '%s\n' "$un_info" | sed -n 's/^FragmentPath=//p')
            if [ -n "$un_fragment" ]; then
                [ "$un_fragment" = "$un_unit" ] && [ -f "$un_unit" ] \
                    || { un_fail "$un_svc 的实际服务来源与目标安装不匹配"; return 1; }
            fi
            [ "$un_state" != loaded ] || [ -n "$un_fragment" ] \
                || { un_fail "$un_svc 缺少实际服务来源"; return 1; }
            un_dropins=$(printf '%s\n' "$un_info" | sed -n 's/^DropInPaths=//p')
            [ -z "$un_dropins" ] || { un_fail "$un_svc 存在额外服务覆盖配置，请先处理"; return 1; }
            if [ "$un_state" = loaded ]; then
                printf '%s\n' "$un_svc" >> "$un_tmp/services" || return 1
            fi
        else
            if [ -f "$un_init" ]; then
                printf '%s\n' "$un_svc" >> "$un_tmp/services" || return 1
            fi
        fi
    done
    un_check_file "$un_etc/hotplug.d/net/99-meta-route" hotplug
}

un_prepare_cron() {
    un_cron_changed=0
    command -v crontab >/dev/null 2>&1 || { un_log '未安装 crontab，跳过定时任务'; return 0; }
    if LC_ALL=C crontab -l > "$un_tmp/cron.old" 2> "$un_tmp/cron.err"; then
        :
    elif grep -Eq 'no crontab for|can.t open.*No such file|cannot open.*No such file' "$un_tmp/cron.err"; then
        return 0
    else
        un_fail '读取 crontab 失败，取消卸载'; return 1
    fi
    awk -v dir="$un_dir" '
        function ends(s,t) { return length(s)>=length(t) && substr(s,length(s)-length(t)+1)==t }
        /^[ \t]*#/ { print; next }
        {
            line=$0; sub(/[ \t]+$/, "", line)
            for (i=1;i<=2;i++) {
                script=(i==1 ? "update-scripts.sh" : "update-all-configs-restart-services.sh")
                marker=(i==1 ? "MyProxy:update-scripts" : "MyProxy:update-configs")
                if (ends(line," sh \047" dir "/sh/" script "\047 # " marker) ||
                    ends(line," sh " dir "/sh/" script " # " marker)) next
                n=split(line,a,/[ \t]+/)
                runner=dir "/sh/run-scheduled-update.sh"
                kind=(i==1 ? "scripts" : "configs")
                if (a[n]==marker && a[n-1]=="#" && a[n-2] ~ /^[0-9]+$/ &&
                    a[n-3]==kind && (a[n-4]==runner || a[n-4]=="\047" runner "\047") && a[n-5]=="sh") next
            }
            print
        }
    ' "$un_tmp/cron.old" > "$un_tmp/cron.new" || return 1
    cmp -s "$un_tmp/cron.old" "$un_tmp/cron.new" || un_cron_changed=1
}

un_check_processes() {
    for un_exe in "$un_proc"/[0-9]*/exe; do
        un_bin=$(readlink "$un_exe" 2>/dev/null) || continue
        case "$un_bin" in "$un_real/core/mihomo"|"$un_real/core/mihomo (deleted)"|\
            "$un_real/agh/AdGuardHome"|"$un_real/agh/AdGuardHome (deleted)")
            un_fail '目标目录的进程仍在运行，保留服务文件和数据，请停止后重试'; return 1 ;;
        esac
    done
}

un_execute() {
    # 先撤掉自动更新任务，避免之后的 cron 再启动服务。
    if [ "$un_cron_changed" -eq 1 ]; then
        crontab "$un_tmp/cron.new" || { un_fail '写入 crontab 失败，取消卸载'; return 1; }
        un_log '已移除目标安装的自动更新任务'
    fi
    while IFS= read -r un_svc; do
        un_log "停止服务：$un_svc"
        if [ "$un_os" = systemd ]; then
            systemctl stop "$un_svc.service" || { un_fail "停止 $un_svc 失败，保留文件和数据"; return 1; }
        else
            service "$un_svc" stop || { un_fail "停止 $un_svc 失败，保留文件和数据"; return 1; }
        fi
    done < "$un_tmp/services"
    un_check_processes || return 1
    if [ "$un_os" = openwrt ]; then
        while IFS= read -r un_svc; do
            service "$un_svc" disable || { un_fail "禁用 $un_svc 自启动失败"; return 1; }
        done < "$un_tmp/services"
    fi
    # systemd 直接移除已核对的启用链接，避免 disable 触发旧 SysV 兼容逻辑。
    while IFS= read -r un_path; do
        rm -f -- "$un_path" || { un_fail "删除自启动项失败：$un_path"; return 1; }
    done < "$un_tmp/links"
    while IFS= read -r un_path; do
        rm -f -- "$un_path" || { un_fail "删除服务文件失败：$un_path"; return 1; }
    done < "$un_tmp/files"
    if [ "$un_os" = systemd ]; then
        systemctl daemon-reload || { un_fail '重新加载 systemd 失败，保留安装数据'; return 1; }
    fi
    if [ "$un_purge" -eq 1 ]; then
        # 在不可逆步骤之前重查安装凭据、符号链接和挂载点。
        un_check_dir && un_check_processes || return 1
        rm -rf -- "$un_dir/core" "$un_dir/agh" "$un_dir/sh" \
            || { un_fail '删除安装数据失败，请检查残留文件'; return 1; }
        un_log '已删除 sh/、core/、agh/；安装根目录及其它文件保留'
    else
        un_log "安装文件已保留：$un_dir"
    fi
    un_log '卸载完成；IPv4 转发设置保持不变'
}

un_cleanup() { [ -z "${un_tmp:-}" ] || rm -rf -- "$un_tmp"; }

un_main() {
    un_parse "$@" || return 1
    if [ "$un_help" -eq 1 ]; then un_usage; return 0; fi
    [ "$(id -u)" = 0 ] || { un_fail '需要 root 权限'; return 1; }
    # 固定系统路径，不从环境读取测试覆盖项；测试仅改写临时脚本副本。
    un_etc=/etc; un_proc=/proc
    un_check_dir || return 1
    if [ -f "$un_etc/openwrt_release" ]; then
        un_os=openwrt
    elif command -v systemctl >/dev/null 2>&1 && [ -d "$un_etc/systemd/system" ]; then
        un_os=systemd
    else
        un_fail '未识别 OpenWrt 或 systemd'; return 1
    fi
    un_tmp=$(mktemp -d) || return 1
    trap un_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    un_preflight_services && un_prepare_cron || return 1
    un_log "卸载目录：$un_dir"
    un_log '将停止目标服务，并清理已核对归属的服务、自启动及 hotplug 文件。'
    if [ "$un_purge" -eq 1 ]; then
        un_log '将永久删除 sh/、core/、agh/，包括密码、配置、订阅及运行数据。'
    else
        un_log '保留安装文件和数据。'
    fi
    if [ "$un_yes" -ne 1 ]; then
        ( : <>/dev/tty ) 2>/dev/null || { un_fail '无交互终端；自动卸载请显式使用 --yes'; return 1; }
        printf '确认卸载？[y/N] ' > /dev/tty
        IFS= read -r un_answer < /dev/tty || un_answer=n
        case "$un_answer" in y|Y|yes|YES|Yes) ;; *) un_log '已取消'; return 0 ;; esac
        # 用户可能在确认界面停留很久，使用最新服务归属和 crontab。
        un_check_dir && un_preflight_services && un_prepare_cron || return 1
    fi
    un_execute
}

# 全部逻辑位于函数内，允许最后删除正在执行的脚本。
un_main "$@"
exit $?
