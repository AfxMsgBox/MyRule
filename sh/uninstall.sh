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
无参数时询问是否删除安装文件，回车默认保留；随后确认卸载。
清理安装器创建的系统集成，并根据安装记录恢复转发设置。
不操作 apk、opkg、apt 或已安装软件包，保留其它程序的任务及系统 cron 服务。
USAGE
}

un_parse() {
    un_dir=/etc/proxy; un_purge=0; un_yes=0; un_help=0; un_seen=' '; un_ask_files=0
    [ "$#" -ne 0 ] || un_ask_files=1
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

# 只读取固定格式的恢复记录，不执行本机配置或备份内容。
un_prepare_forward() {
    un_forward_state="$un_dir/sh/.install-state/forward"
    un_forward_known=0
    [ -e "$un_forward_state" ] || [ -L "$un_forward_state" ] || return 0
    [ ! -L "$un_dir/sh/.install-state" ] && [ ! -L "$un_forward_state" ] \
        || { un_fail '转发恢复记录不能是符号链接'; return 1; }
    for un_part in owner platform existed before after runtime; do
        [ -f "$un_forward_state/$un_part" ] && [ ! -L "$un_forward_state/$un_part" ] \
            || { un_fail '转发恢复记录不完整'; return 1; }
    done
    [ "$(cat "$un_forward_state/owner")" = "$un_dir" ] \
        && [ "$(cat "$un_forward_state/platform")" = "$un_os" ] \
        || { un_fail '转发恢复记录的安装目录或平台不匹配'; return 1; }
    if [ -f "$un_forward_state/restored" ]; then
        un_forward_known=2
        return 0
    fi
    un_forward_existed=$(cat "$un_forward_state/existed")
    un_forward_old=$(cat "$un_forward_state/runtime")
    case "$un_forward_existed:$un_forward_old" in 0:0|0:1|1:0|1:1) ;;
        *) un_fail '转发恢复记录的值无效'; return 1 ;;
    esac
    case "$un_os" in
        systemd) un_forward_conf="$un_etc/sysctl.d/99-zz-myproxy.conf" ;;
        openwrt) un_forward_conf="$un_etc/sysctl.conf" ;;
    esac
    [ ! -L "$un_forward_conf" ] \
        || { un_fail '转发配置已变为符号链接，拒绝覆盖'; return 1; }
    if [ -e "$un_forward_conf" ]; then
        [ -f "$un_forward_conf" ] &&
            { cmp -s "$un_forward_conf" "$un_forward_state/after" ||
              cmp -s "$un_forward_conf" "$un_forward_state/before"; } \
            || { un_fail '转发配置在安装后被修改，无法自动恢复；请先核对 .install-state/forward 中的快照'; return 1; }
    elif [ "$un_forward_existed" = 1 ]; then
        un_fail '原转发配置文件已被移除，拒绝自动重建'; return 1
    fi
    un_forward_known=1
}

un_restore_forward() {
    un_prepare_forward || return 1
    [ "$un_forward_known" -ne 2 ] || return 0
    if [ "$un_forward_known" -ne 1 ]; then
        un_log '没有安装前的转发记录，保留现有 IPv4 转发设置（旧安装无法自动恢复）。'
        return 0
    fi
    # 只恢复文件仍与安装快照一致的内容；恢复失败保留记录和安装数据供重试。
    if [ "$un_forward_existed" = 0 ]; then
        rm -f -- "$un_forward_conf" || return 1
    elif ! cmp -s "$un_forward_conf" "$un_forward_state/before"; then
        un_forward_tmp=$(mktemp "$un_forward_conf.XXXXXX") || return 1
        if ! cp -p "$un_forward_state/before" "$un_forward_tmp" ||
            ! mv "$un_forward_tmp" "$un_forward_conf"; then
            rm -f -- "$un_forward_tmp"
            un_fail '恢复转发配置文件失败'; return 1
        fi
    fi
    un_forward_current=$(cat "$un_proc/sys/net/ipv4/ip_forward" 2>/dev/null) \
        || { un_fail '无法读取当前转发状态，保留恢复记录'; return 1; }
    if [ "$un_forward_current" != "$un_forward_old" ]; then
        if [ "$un_forward_current" = 1 ] && [ "$un_forward_old" = 0 ]; then
            sysctl -w net.ipv4.ip_forward=0 \
                || { un_fail '恢复转发运行值失败，保留记录和安装数据'; return 1; }
            [ "$(cat "$un_proc/sys/net/ipv4/ip_forward" 2>/dev/null)" = 0 ] \
                || { un_fail '转发原值未生效，保留记录和安装数据'; return 1; }
        else
            un_log '转发运行值已被外部修改，保留当前值。'
        fi
    fi
    : > "$un_forward_state/restored" || return 1
    un_log '已恢复安装前的 IPv4 转发配置'
}

un_cleanup_route() {
    un_route_record="$un_dir/core/.fake-ip-route"
    [ -e "$un_route_record" ] || [ -L "$un_route_record" ] || return 0
    [ -f "$un_route_record" ] && [ ! -L "$un_route_record" ] \
        || { un_fail '路由记录不是普通文件'; return 1; }
    awk 'NR!=1 || NF!=4 { exit 1 }
        { n=split($1,a,"/"); if(n!=2 || a[2]!~/^[0-9]+$/ || a[2]<1 || a[2]>32) exit 1;
          n=split(a[1],b,"."); if(n!=4) exit 1;
          for(i=1;i<=4;i++) if(b[i]!~/^[0-9]+$/ || b[i]>255) exit 1;
          if($2!~/^[a-zA-Z0-9_-]+$/ || $3!~/^[0-9]+$/ || $4!~/^[a-f0-9-]+$/) exit 1 }
        END { if(NR!=1) exit 1 }' "$un_route_record" \
        || { un_fail '路由记录格式无效'; return 1; }
    read -r un_route_cidr un_route_dev un_route_index un_route_boot < "$un_route_record" || return 1
    un_current_boot=$(cat "$un_proc/sys/kernel/random/boot_id" 2>/dev/null) \
        || { un_fail '无法确认路由所属的启动周期'; return 1; }
    if [ "$un_current_boot" != "$un_route_boot" ]; then
        un_log '路由记录来自上次开机，保留当前路由。'
        rm -f -- "$un_route_record"
        return $?
    fi
    # TUN 销毁时内核会自动删除路由；接口重建后即使同名也不属于原记录。
    if [ -e "$un_sys/class/net/$un_route_dev/ifindex" ]; then
        un_route_current=$(cat "$un_sys/class/net/$un_route_dev/ifindex") || return 1
        if [ "$un_route_current" = "$un_route_index" ]; then
            ip -4 route show exact "$un_route_cidr" dev "$un_route_dev" > "$un_tmp/routes" \
                || { un_fail '查询残留路由失败'; return 1; }
            if [ -s "$un_tmp/routes" ]; then
                # 仅删路由修复脚本写入的直连接口路由，不删 via 网关路由。
                awk -v cidr="$un_route_cidr" -v dev="$un_route_dev" '
                    $1!=cidr || $2!="dev" || $3!=dev { exit 1 }
                    / via / { exit 1 }
                    END { if(NR!=1) exit 1 }' "$un_tmp/routes" \
                    || { un_fail '路由已被修改，拒绝删除'; return 1; }
                ip -4 route del "$un_route_cidr" dev "$un_route_dev" \
                    || { un_fail '删除残留 fake-ip 路由失败'; return 1; }
            fi
        else
            un_log '同名 TUN 接口已重建，保留其路由。'
        fi
    fi
    rm -f -- "$un_route_record"
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
    un_cleanup_route || return 1
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
    un_restore_forward || return 1
    if [ "$un_purge" -eq 1 ]; then
        # 在不可逆步骤之前重查安装凭据、符号链接和挂载点。
        un_check_dir && un_check_processes || return 1
        rm -rf -- "$un_dir/core" "$un_dir/agh" "$un_dir/sh" \
            || { un_fail '删除安装数据失败，请检查残留文件'; return 1; }
        un_log '已删除 sh/、core/、agh/；安装根目录及其它文件保留'
    else
        un_log "安装文件已保留：$un_dir"
    fi
    un_log '卸载完成；未操作包管理器、软件包及系统 cron 服务'
}

un_cleanup() { [ -z "${un_tmp:-}" ] || rm -rf -- "$un_tmp"; }

un_main() {
    un_parse "$@" || return 1
    if [ "$un_help" -eq 1 ]; then un_usage; return 0; fi
    [ "$(id -u)" = 0 ] || { un_fail '需要 root 权限'; return 1; }
    # 固定系统路径，不从环境读取测试覆盖项；测试仅改写临时脚本副本。
    un_etc=/etc; un_proc=/proc
    un_sys=/sys
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
    un_preflight_services && un_prepare_cron && un_prepare_forward || return 1
    un_log "卸载目录：$un_dir"
    un_log '将停止目标服务，并清理已核对归属的服务、自启动及 hotplug 文件。'
    if [ "$un_ask_files" -eq 1 ]; then
        ( : <>/dev/tty ) 2>/dev/null || { un_fail '无交互终端；自动卸载请显式使用 --yes'; return 1; }
        un_log "可删除 $un_dir 下的 sh/、core/、agh/，包括程序、配置及运行数据。"
        while :; do
            printf '是否删除安装文件和数据？[y/N] ' > /dev/tty
            IFS= read -r un_answer < /dev/tty || { un_log '已取消'; return 0; }
            case "$un_answer" in
                y|Y|yes|YES|Yes) un_purge=1; break ;;
                ''|n|N|no|NO|No) break ;;
                *) un_log '请输入 y 或 n；回车保留文件。' ;;
            esac
        done
        un_check_dir || return 1
    fi
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
        un_check_dir && un_preflight_services && un_prepare_cron && un_prepare_forward || return 1
    fi
    un_execute
}

# 全部逻辑位于函数内，允许最后删除正在执行的脚本。
un_main "$@"
exit $?
