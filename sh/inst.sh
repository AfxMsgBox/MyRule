#!/bin/sh
# MyProxy 一键安装：交互式收集敏感参数 → 下载脚本/服务文件/二进制 → 渲染配置 → 可选启动服务。
#
# 用法（需 root；第一位置参数 = 安装根，省略用 $PWD）：
#   mkdir -p /opt/myproxy && cd $_ && sh inst.sh        # 装到 /opt/myproxy/{sh,core,agh}
#   sh inst.sh /etc/proxy                                # 显式指定，装到 /etc/proxy/{sh,core,agh}
# wget|sh 管道（向导从 /dev/tty 读，不吃脚本流）：
#   mkdir -p /opt/myproxy && cd $_
#   wget -O- https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/inst.sh | sh
# 自托管 / 分支调试：
#   export MP_REPO_RAW_URL=https://raw.githubusercontent.com/AfxMsgBox/MyRule/refs/heads/<branch>
#   wget -O- "$MP_REPO_RAW_URL/sh/inst.sh" | sh

[ "$(id -u)" = "0" ] || { echo "需要 root 权限运行（Debian/Ubuntu 请加 sudo）" >&2; exit 1; }

# === 颜色（tty 启用；设 NO_COLOR=1 禁用）===
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_R=$(printf '\033[0m');    C_D=$(printf '\033[2m');    C_B=$(printf '\033[1m')
    C_RED=$(printf '\033[31m'); C_GRN=$(printf '\033[32m'); C_YEL=$(printf '\033[33m')
    C_BLU=$(printf '\033[34m'); C_CYN=$(printf '\033[36m')
else
    C_R= C_D= C_B= C_RED= C_GRN= C_YEL= C_BLU= C_CYN=
fi
say_section() { printf '\n%s\n' "${C_B}${C_CYN}━━━ $* ━━━${C_R}"; }
say_step()    { printf '%s\n'   "${C_B}${C_BLU}>>>${C_R} ${C_B}$*${C_R}"; }
say_ok()      { printf '%s\n'   "${C_GRN}$*${C_R}"; }
say_warn()    { printf '%s\n'   "${C_YEL}$*${C_R}"; }
say_err()     { printf '%s\n'   "${C_RED}$*${C_R}"; }
say_dim()     { printf '%s\n'   "${C_D}$*${C_R}"; }

# === 路径 ===
DIR_INST="${1:-$PWD}"
DIR_SH="$DIR_INST/sh"
DIR_CORE="$DIR_INST/core"
DIR_AGH="$DIR_INST/agh"
mkdir -p "$DIR_SH/etc" "$DIR_CORE" "$DIR_AGH"

# === OS 识别：common.sh 还没加载，先就地探测 ===
if [ -f /etc/openwrt_release ] || grep -qs '^ID=.*openwrt' /etc/os-release; then
    os_type=openwrt
elif command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ]; then
    os_type=systemd
else
    echo "未识别 OpenWrt 或 systemd 系统" >&2
    exit 1
fi

say_section "MyProxy 安装向导"
printf '%s\n' "${C_B}目标系统${C_R}    $os_type"
printf '%s\n' "${C_B}安装根目录${C_R}  $DIR_INST"
say_dim "  脚本 → $DIR_SH    (含 sh/etc/ 服务文件副本)"
say_dim "  core → $DIR_CORE"
say_dim "  agh  → $DIR_AGH"

# === 开启 IPv4 转发（透明代理网关需要）===
# 写入通用的 /etc/sysctl.conf 保证重启后仍生效；LXC 权限不足时只警告，不中断安装。
say_section "启用 IPv4 转发"
sysctl_conf=/etc/sysctl.conf
forward_persisted=0
if grep -Eq '^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=' "$sysctl_conf" 2>/dev/null; then
    sed -i -E 's/^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=.*/net.ipv4.ip_forward=1/' "$sysctl_conf" \
        && forward_persisted=1
else
    printf '\nnet.ipv4.ip_forward=1\n' >> "$sysctl_conf" \
        && forward_persisted=1
fi

forward_applied=0
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 && forward_applied=1
if [ "$forward_applied" = "1" ] && [ "$forward_persisted" = "1" ]; then
    say_ok "net.ipv4.ip_forward = 1（已立即生效并持久化）"
elif [ "$forward_applied" = "1" ]; then
    say_warn "net.ipv4.ip_forward 已立即生效，但无法写入 $sysctl_conf"
elif [ "$forward_persisted" = "1" ]; then
    say_warn "无法立即设置 net.ipv4.ip_forward；已写入 $sysctl_conf，请检查 LXC 权限或宿主机限制"
else
    say_warn "无法设置或持久化 net.ipv4.ip_forward，请检查 LXC 权限或宿主机限制"
fi

# === 预加载已有 env.local.conf（提供重装场景的默认值） ===
# 调用方显式传入的 MP_* 仍优先于旧本机配置，与 env.conf 的优先级保持一致。
inst_env_override=$(export -p 2>/dev/null | grep -E ' MP_[A-Za-z0-9_]+=' || true)
[ -f "$DIR_SH/env.local.conf" ] && . "$DIR_SH/env.local.conf"
[ -n "$inst_env_override" ] && eval "$inst_env_override"
unset inst_env_override

# 安装与日常更新共用一个外部代理变量；运行后仍首选本机 Core。

# === 交互向导：能读 /dev/tty 就开问，否则跳过 ===
HAVE_TTY=0
{ : >/dev/tty; } 2>/dev/null && [ -r /dev/tty ] && HAVE_TTY=1

# prompt_to <var> <default> <label> [hint_lines...]
#   HAVE_TTY=0 时直接把 default 赋给 var；=1 时显示 label / hint / [default] 等输入
prompt_to() {
    _p_var=$1; _p_def=$2; _p_label=$3
    shift 3
    [ "$HAVE_TTY" = "1" ] || { eval "$_p_var=\$_p_def"; return; }
    printf '\n%s%s%s\n' "${C_B}${C_CYN}" "$_p_label" "${C_R}" >/dev/tty
    for _p_hint in "$@"; do printf '  %s%s%s\n' "${C_D}" "$_p_hint" "${C_R}" >/dev/tty; done
    if [ -n "$_p_def" ]; then
        printf '  %s[%s]%s\n  %s>%s ' "${C_D}" "$_p_def" "${C_R}" "${C_GRN}" "${C_R}" >/dev/tty
    else
        printf '  %s[空]%s\n  %s>%s ' "${C_D}" "${C_R}" "${C_GRN}" "${C_R}" >/dev/tty
    fi
    IFS= read -r _p_val </dev/tty || _p_val=""
    [ -n "$_p_val" ] || _p_val="$_p_def"
    eval "$_p_var=\$_p_val"
}

# 分支名 → 完整 raw URL；完整 URL 原样保留
expand_branch() {
    case "$1" in
        http://*|https://*) printf '%s' "$1" ;;
        main|"")            printf 'https://raw.githubusercontent.com/AfxMsgBox/MyRule/main' ;;
        *)                  printf 'https://raw.githubusercontent.com/AfxMsgBox/MyRule/refs/heads/%s' "$1" ;;
    esac
}

if [ "$HAVE_TTY" = "1" ]; then
    # 从已有 URL 反推当前分支（main 默认显示 "main"）
    case "$MP_REPO_RAW_URL" in
        */refs/heads/*) cur_branch="${MP_REPO_RAW_URL##*/refs/heads/}" ;;
        */main|"")      cur_branch="main" ;;
        *)              cur_branch="$MP_REPO_RAW_URL" ;;
    esac

    prompt_to in_branch "$cur_branch" "[1/9] 仓库分支或 GitHub Raw 根 URL" \
        "主分支:   main" \
        "指定分支: claude/update-readme-overview-pU5D3" \
        "GitHub Raw: https://raw.githubusercontent.com/owner/repo/refs/heads/dev"
    MP_REPO_RAW_URL=$(expand_branch "$in_branch")

    # 安装时是外部代理；安装完成后自然成为 Core 不可用时的后备代理。
    while :; do
        if [ -n "$MP_PROXY" ]; then
            prompt_to in_proxy "2" "[2/9] 本次安装使用的代理" \
                "1) 直连" \
                "2) 使用现有代理: $MP_PROXY" \
                "3) 修改代理 URL" \
                "安装代理会保存为日常更新的后备代理"
            case "$in_proxy" in
                1) MP_PROXY=""; break ;;
                2) break ;;
                3) prompt_to in_proxy_url "$MP_PROXY" \
                       "      代理 URL（http://、https://、socks5:// 或 socks5h://）"
                   case "$in_proxy_url" in
                       http://*|https://*|socks5://*|socks5h://*) MP_PROXY=$in_proxy_url; break ;;
                       *) say_err "      不支持的代理 URL" ;;
                   esac ;;
                *) say_err "      请输入 1 / 2 / 3" ;;
            esac
        else
            prompt_to in_proxy "1" "[2/9] 本次安装使用的代理" \
                "1) 直连" \
                "2) 手工输入代理 URL" \
                "安装代理会保存为日常更新的后备代理"
            case "$in_proxy" in
                1) break ;;
                2) prompt_to in_proxy_url "socks5h://127.0.0.1:1080" \
                       "      代理 URL（http://、https://、socks5:// 或 socks5h://）"
                   case "$in_proxy_url" in
                       http://*|https://*|socks5://*|socks5h://*) MP_PROXY=$in_proxy_url; break ;;
                       *) say_err "      不支持的代理 URL" ;;
                   esac ;;
                *) say_err "      请输入 1 / 2" ;;
            esac
        fi
    done
    export MP_PROXY

    prompt_to MP_SUBSCRIBE_URL "$MP_SUBSCRIBE_URL" "[3/9] 节点订阅 URL / MP_SUBSCRIBE_URL"
    prompt_to MP_AGH_USER_NAME "$MP_AGH_USER_NAME" "[4/9] AdGuardHome 管理员用户名 / MP_AGH_USER_NAME"

    # 密码：必须是 bcrypt 哈希（$2a$ / $2b$ / $2y$）；不合法循环重问
    while :; do
        prompt_to MP_AGH_PASSWORD "$MP_AGH_PASSWORD" \
            "[5/9] AdGuardHome 管理员密码（bcrypt 哈希，\$2a\$/\$2y\$ 开头）" \
            "生成: htpasswd -bnBC 10 '' '明文' | cut -d: -f2     # apache2-utils" \
            "      mkpasswd -m bcrypt-a '明文'                    # Debian: apt install whois" \
            "      python3 -c \"import bcrypt;print(bcrypt.hashpw(b'明文',bcrypt.gensalt(10)).decode())\""
        case "$MP_AGH_PASSWORD" in
            '$2a$'*|'$2b$'*|'$2y$'*) break ;;
            '') say_err "      错误：不能为空。" ;;
            *)  say_err "      错误：必须是 bcrypt 哈希（\$2a\$/\$2b\$/\$2y\$ 开头）。" ;;
        esac
    done

    : "${MP_LOCAL_DNS:=223.5.5.5 119.29.29.29}"
    prompt_to MP_LOCAL_DNS "$MP_LOCAL_DNS" "[6/9] AGH 上游 DNS / MP_LOCAL_DNS"
else
    # 非交互：env.local.conf 必须已具备必填项
    : "${MP_REPO_RAW_URL:=https://raw.githubusercontent.com/AfxMsgBox/MyRule/main}"
    miss=
    [ -n "$MP_SUBSCRIBE_URL" ] || miss="$miss MP_SUBSCRIBE_URL"
    [ -n "$MP_AGH_USER_NAME" ] || miss="$miss MP_AGH_USER_NAME"
    [ -n "$MP_AGH_PASSWORD" ] || miss="$miss MP_AGH_PASSWORD"
    [ -z "$miss" ] || { echo "无 tty 且 env.local.conf 缺：$miss" >&2; exit 1; }
fi
export MP_PROXY

# === 写 env.local.conf ===
# upsert_conf <key> <value> <file>：已存在则替换，否则追加。
# 值用单引号包裹防止 $ 被 source 时再次展开（bcrypt 哈希含 $）；
# 值里出现的单引号转义为 '\''
upsert_conf() {
    _uc_key=$1; _uc_val=$2; _uc_file=$3
    _uc_esc=$(printf '%s' "$_uc_val" | sed "s/'/'\\\\''/g")
    _uc_line="$_uc_key='$_uc_esc'"
    if grep -q "^$_uc_key=" "$_uc_file" 2>/dev/null; then
        awk -v k="$_uc_key" -v repl="$_uc_line" '
            $0 ~ "^" k "=" { print repl; next }
            { print }
        ' "$_uc_file" > "$_uc_file.tmp" && mv "$_uc_file.tmp" "$_uc_file"
    else
        printf '%s\n' "$_uc_line" >> "$_uc_file"
    fi
}

say_section "写入 env.local.conf"
say_dim "$DIR_SH/env.local.conf"
[ -f "$DIR_SH/env.local.conf" ] || : > "$DIR_SH/env.local.conf"
kv_keys="MP_INST_DIR MP_REPO_RAW_URL MP_PROXY MP_SUBSCRIBE_URL MP_AGH_USER_NAME MP_AGH_PASSWORD MP_LOCAL_DNS"
for kv_key in $kv_keys; do
    eval "kv_val=\$$kv_key"
    case "$kv_key" in
        MP_INST_DIR) kv_val="$DIR_INST" ;;
    esac
    upsert_conf "$kv_key" "$kv_val" "$DIR_SH/env.local.conf"
done
chmod 0600 "$DIR_SH/env.local.conf"

# === Bootstrap：先拿到 env.conf + common.sh，足以 source 后用 mp_fetch_repo_sh ===
bootstrap_download() {
    _bd_url=$1; _bd_dst=$2; _bd_tmp="$_bd_dst.tmp"
    while :; do
        rm -f "$_bd_tmp"
        _bd_ok=0
        if [ -n "$MP_PROXY" ]; then
            curl --progress-bar --show-error --fail -L --connect-timeout 10 --max-time 300 \
                --proxy "$MP_PROXY" "$_bd_url" -o "$_bd_tmp" \
                && [ -s "$_bd_tmp" ] && _bd_ok=1
        fi
        if [ "$_bd_ok" -eq 0 ]; then
            curl --progress-bar --show-error --fail -L --connect-timeout 10 --max-time 300 \
                --noproxy '*' "$_bd_url" -o "$_bd_tmp" \
                && [ -s "$_bd_tmp" ] && _bd_ok=1
        fi
        if [ "$_bd_ok" -eq 1 ]; then
            mv "$_bd_tmp" "$_bd_dst"
            return 0
        fi
        rm -f "$_bd_tmp"
        [ "$HAVE_TTY" = "1" ] || return 1
        printf '下载失败，是否重试？[Y/n] ' >/dev/tty
        IFS= read -r _bd_retry </dev/tty || _bd_retry=n
        case "$_bd_retry" in n|N|no|NO|No) return 1 ;; esac
    done
}

say_section "Bootstrap"
say_step "下载 env.conf / common.sh"
bootstrap_download "$MP_REPO_RAW_URL/sh/env.conf"  "$DIR_SH/env.conf"  || { say_err "下载 env.conf 失败"  >&2; exit 1; }
bootstrap_download "$MP_REPO_RAW_URL/sh/common.sh" "$DIR_SH/common.sh" || { say_err "下载 common.sh 失败" >&2; exit 1; }

export MP_INST_DIR="$DIR_INST"            # 显式声明根（init.d/$0 不可靠）
. "$DIR_SH/common.sh"                     # 加载公共函数

# === 用 tarball 一次拉齐 sh/ 整树（含 env.conf / common.sh / 所有 *.sh / sh/etc/*）===
# 覆盖刚 bootstrap 的 2 个文件无害；env.local.conf 不在 tarball 里所以不会动
say_step "拉取仓库 sh/ 整树"
mp_fetch_repo_sh "$DIR_SH" || { say_err "tarball 下载失败"; exit 1; }

# === sh/etc 路径占位替换（是否 cp 到 /etc 由后面 autostart 决定） ===
etc_rels=$(mp_etc_rels)
say_step "sh/etc 路径替换 /etc/proxy → $DIR_INST"
mp_sync_etc_files never || { say_err "处理 sh/etc 失败"; exit 1; }

# === 先生成 Core 配置并预下载 providers ===
# 后续脚本所需的代理端口、API、DNS、UI、TUN 和 fake-ip 均以该配置为准。
say_section "生成 Core 配置"
sh "$DIR_SH/update-core-config.sh" \
    || { say_err "Core 配置或 provider 下载失败，停止安装"; exit 1; }

# === 下载内核二进制（mihomo / AdGuardHome）===
# metacubexd 的目标目录从上一步 config.yaml 的 external-ui 读取。
say_section "下载内核二进制"
sh "$DIR_SH/update-bin.sh" \
    || { say_err "二进制或 UI 下载失败，停止安装"; exit 1; }

# === 下载并渲染 agh.yaml，同时预下载其中的 filters ===
say_section "渲染 AGH 配置"
say_dim "$MP_AGH_DIR/agh.yaml"
say_step "下载模板并预下载 AGH filters"
mp_prepare_agh_config "$MP_AGH_DIR/agh.yaml" "$MP_CORE_DIR/config.yaml" \
    || { say_err "AGH 配置或 filter 下载失败，停止安装"; exit 1; }
say_ok "agh.yaml 已生成"

# === 生成 AGH dns.conf；Core DNS 地址从 config.yaml 读取 ===
say_section "生成 AGH dns.conf"
sh "$DIR_SH/update-agh-config.sh" \
    || { say_err "AGH dns.conf 生成失败，停止安装"; exit 1; }

# === [7/9] 自启动询问 ===
# Y：把 $DIR_SH/etc 下文件复制到 /etc 对应位置并 enable+start
# n：不动 /etc；服务文件留在 $DIR_SH/etc，可后续手动 cp 或重跑 inst 选 Y
prompt_to autostart "Y" "[7/9] 现在启用并启动系统服务？(Y/n)" \
    "Y = 把 $DIR_SH/etc 下文件复制到 /etc 对应位置，并 enable + start" \
    "n = 跳过；服务文件留在 $DIR_SH/etc，可后续按下面命令手动装"

case "$autostart" in
    n|N|no|NO|No)
        say_section "已跳过自启动"
        say_dim "服务文件保留在 $DIR_SH/etc/；手动启用："
        case "$os_type" in
            openwrt)
                for rel in $etc_rels; do
                    say_dim "  cp $DIR_SH/etc/$rel  /etc/$rel  && chmod +x /etc/$rel"
                done
                say_dim "  service proxy_core enable && service proxy_core start"
                say_dim "  # 确认 Core API 就绪后："
                say_dim "  service agh enable && service agh start"
                ;;
            systemd)
                for rel in $etc_rels; do
                    say_dim "  cp $DIR_SH/etc/$rel  /etc/$rel"
                done
                say_dim "  systemctl daemon-reload"
                say_dim "  mkdir -p /etc/systemd/system/multi-user.target.wants"
                say_dim "  ln -sf /etc/systemd/system/proxy_core.service /etc/systemd/system/multi-user.target.wants/proxy_core.service"
                say_dim "  ln -sf /etc/systemd/system/agh.service /etc/systemd/system/multi-user.target.wants/agh.service"
                say_dim "  systemctl start proxy_core.service"
                say_dim "  # 确认 Core API 就绪后："
                say_dim "  systemctl start agh.service"
                ;;
        esac
        ;;
    *)
        say_section "安装服务文件到 /etc 并启动"
        mp_sync_etc_files always \
            || { say_err "安装服务文件失败"; exit 1; }
        mp_service_op enable_start proxy_core \
            || { say_err "Core 服务启动失败，未启动 AGH"; exit 1; }
        say_step "等待 Core API 就绪"
        mp_wait_core_ready 30 \
            || { say_err "Core 未就绪，未启动 AGH"; exit 1; }
        mp_service_op enable_start agh \
            || { say_err "AGH 服务启动失败"; exit 1; }
        ;;
esac

# === 定时更新：输入间隔天数，默认 3；输入 n 跳过 ===
# 使用 root crontab：脚本固定 03:00，配置固定 03:05；重复安装时按 marker 替换。
install_cron_job() {
    _cj_marker=$1; _cj_days=$2; _cj_script=$3; _cj_minute=$4
    _cj_tmp=$(mktemp) || return 1
    crontab -l > "$_cj_tmp" 2>/dev/null || :
    awk -v marker="$_cj_marker" 'index($0, marker) == 0 { print }' "$_cj_tmp" > "$_cj_tmp.new"
    printf "%s 3 */%s * * sh '%s' # %s\n" \
        "$_cj_minute" "$_cj_days" "$_cj_script" "$_cj_marker" >> "$_cj_tmp.new"
    if crontab "$_cj_tmp.new"; then
        rm -f "$_cj_tmp" "$_cj_tmp.new"
        return 0
    fi
    rm -f "$_cj_tmp" "$_cj_tmp.new"
    return 1
}

prompt_cron_days() {
    _pcd_var=$1; _pcd_label=$2
    while :; do
        prompt_to "$_pcd_var" "3" "$_pcd_label" \
            "输入 1-31 表示每隔多少天执行；默认 3 天" \
            "输入 n 跳过此定时任务"
        eval "_pcd_value=\$$_pcd_var"
        case "$_pcd_value" in
            n|N|no|NO|No) return 1 ;;
            ''|*[!0-9]*) say_err "      请输入 1-31，或输入 n 跳过。" ;;
            *)
                if [ "$_pcd_value" -ge 1 ] 2>/dev/null && [ "$_pcd_value" -le 31 ]; then
                    return 0
                fi
                say_err "      天数必须在 1-31 之间。"
                ;;
        esac
    done
}

if [ "$HAVE_TTY" = "1" ]; then
    say_section "设置定时更新"
    if ! command -v crontab >/dev/null 2>&1; then
        say_warn "系统未安装 crontab，跳过定时任务设置"
    else
        cron_changed=0
        if prompt_cron_days cron_script_days "[8/9] 定时更新脚本的间隔天数"; then
            if install_cron_job "MyProxy:update-scripts" "$cron_script_days" \
                    "$DIR_SH/update-scripts.sh" 0; then
                say_ok "脚本：每 $cron_script_days 天 03:00 更新"
                cron_changed=1
            else
                say_warn "脚本定时任务写入失败"
            fi
        else
            say_dim "已跳过脚本定时更新"
        fi

        if prompt_cron_days cron_config_days "[9/9] 定时更新配置文件的间隔天数"; then
            if install_cron_job "MyProxy:update-configs" "$cron_config_days" \
                    "$DIR_SH/update-all-configs-restart-services.sh" 5; then
                say_ok "配置文件：每 $cron_config_days 天 03:05 更新并重启服务"
                cron_changed=1
            else
                say_warn "配置文件定时任务写入失败"
            fi
        else
            say_dim "已跳过配置文件定时更新"
        fi
        if [ "$cron_changed" -eq 1 ] && [ "$os_type" = openwrt ]; then
            if /etc/init.d/cron enable >/dev/null 2>&1 \
               && /etc/init.d/cron restart >/dev/null 2>&1; then
                say_ok "OpenWrt cron 服务已启用并重启"
            else
                say_warn "定时任务已写入，但 OpenWrt cron 服务启用或重启失败"
            fi
        fi
    fi
fi

say_section "安装完成"
printf '%s  %s\n' "${C_B}安装目录${C_R}" "$DIR_INST"
printf '%s  %s%s%s   用户名 %s\n' "${C_B}AGH Web ${C_R}" "${C_CYN}" "http://<本机IP>:180" "${C_R}" "$MP_AGH_USER_NAME"
case "$os_type" in
    openwrt) printf '%s  %slogread -e MyProxy -f%s\n' "${C_B}日志    ${C_R}" "${C_D}" "${C_R}" ;;
    systemd) printf '%s  %sjournalctl -t MyProxy -f%s\n' "${C_B}日志    ${C_R}" "${C_D}" "${C_R}" ;;
esac
printf '\n%s\n' "${C_B}以后刷新${C_R}"
say_dim "  脚本:   sh $DIR_SH/update-scripts.sh"
say_dim "  配置:   sh $DIR_SH/update-all-configs.sh   # 或单独跑 update-agh-config.sh / update-core-config.sh / update-proxy-rule.sh"
say_dim "  二进制: sh $DIR_SH/update-bin.sh"
