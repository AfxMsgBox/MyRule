#!/bin/sh
# 安装器公共逻辑：参数和交互、依赖、仓库与资源准备、目标应用。
# 仅 --installer-run 入口执行主流程，其它情况可安全 source 函数。

# === ui ===

inst_colors() {
    C_R= C_D= C_B= C_RED= C_GRN= C_YEL= C_BLU= C_CYN=
    T_R= T_B= T_CYN=
    if [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != dumb ]; then
        if [ -t 1 ]; then
            C_R=$(printf '\033[0m'); C_D=$(printf '\033[2m'); C_B=$(printf '\033[1m')
            C_RED=$(printf '\033[31m'); C_GRN=$(printf '\033[32m'); C_YEL=$(printf '\033[33m')
            C_BLU=$(printf '\033[34m'); C_CYN=$(printf '\033[36m')
        fi
        if [ -t 3 ]; then
            T_R=$(printf '\033[0m'); T_B=$(printf '\033[1m'); T_CYN=$(printf '\033[36m')
        fi
    fi
    _inst_step=0
}

say_section() {
    _inst_step=$((_inst_step + 1))
    printf '\n%s[%02d] %s%s\n' "${C_B}${C_BLU}" "$_inst_step" "$*" "$C_R"
}

say_step() { printf '  %s[执行]%s %s\n' "$C_CYN" "$C_R" "$*"; }
say_ok() { printf '  %s[成功]%s %s\n' "$C_GRN" "$C_R" "$*"; }
say_warn() { printf '  %s[警告]%s %s\n' "$C_YEL" "$C_R" "$*"; }
say_err() { printf '  %s[失败]%s %s\n' "$C_RED" "$C_R" "$*"; }
say_dim() { printf '  %s%s%s\n' "$C_D" "$*" "$C_R"; }

prompt_to() {
    _p_var=$1; _p_def=$2; _p_label=$3; shift 3
    [ "$INSTALL_MODE" = interactive ] || { eval "$_p_var=\$_p_def"; return 0; }
    printf '\n%s%s%s\n' "${T_B}${T_CYN}" "$_p_label" "$T_R" >&3
    for _p_hint in "$@"; do printf '  %s\n' "$_p_hint" >&3; done
    printf '  [%s] > ' "${_p_def:-空}" >&3
    IFS= read -r _p_val <&3 || { say_err '输入已结束，取消安装'; exit 1; }
    [ -n "$_p_val" ] || _p_val=$_p_def
    eval "$_p_var=\$_p_val"
}

# === options ===
# 用户接口只在此处定义；值赋给固定变量，不 eval 用户文本。
inst_usage() {
    cat <<'USAGE'
MyRule 安装器
  sh inst.sh                         交互选择安装方式
  sh inst.sh [选项]                   命令行安装

必填：--subscribe-url URL
认证：--agh-password BCRYPT          设置密码哈希；与 --no-auth 二选一
      --no-auth                      关闭 AGH 登录认证
      --agh-user USER                管理员用户名，默认 admin
来源：--branch NAME                  GitHub / 后续更新分支，默认 main
      --local                        使用 inst.sh 所在的本地仓库
      --source-dir DIR               显式指定本地仓库
目标：--target USER@HOST             通过 SSH 安装；省略则安装到本机
      --ssh-port PORT                SSH 端口，默认 22
      --ssh-key FILE                 SSH 私钥；也支持默认密钥与 agent
      --ssh-auth auto|password|key   认证方式，默认 auto；密码由 SSH 提示
配置：--install-dir DIR              目标安装目录，默认 /etc/proxy
      --dns 'DNS1 DNS2'              默认 '223.5.5.5 119.29.29.29'；空值用目标机 DNS
      --proxy URL                    目标机后备代理，默认空
      --download-proxy URL           发起端下载代理；不写入目标机配置
      --scripts-days N               脚本更新间隔 1–365 天；省略保留旧任务
      --configs-days N               配置更新间隔 1–365 天；省略保留旧任务
      --no-start                     暂不启用新配置和服务
      --interactive                  带参数继续交互收集其余选项
      --help                         显示帮助
支持 --选项=值。SSH 的用户名、密码和密钥认证独立于安装参数。
USAGE
}

inst_parse_args() {
    INSTALL_MODE=silent; [ "$#" -ne 0 ] || INSTALL_MODE=interactive
    _inst_help=0; _inst_seen=' '; _MP_SOURCE_DIR=; INST_LOCAL=0
    DIR_INST=/etc/proxy; MP_REPO_BRANCH=main; MP_LOCAL_DNS='223.5.5.5 119.29.29.29'
    MP_PROXY=; MP_SUBSCRIBE_URL=; MP_AGH_USER_NAME=admin; MP_AGH_PASSWORD=; INST_NO_AUTH=0
    INST_TARGET=; INST_SSH_PORT=22; INST_SSH_KEY=; INST_SSH_AUTH=auto
    INST_DOWNLOAD_PROXY=${_INST_BOOT_PROXY:-}; INST_DOWNLOAD_PROXY_SET=0
    [ "${_INST_BOOT_PROXY+x}" != x ] || INST_DOWNLOAD_PROXY_SET=1
    autostart=Y; cron_script_days=n; cron_config_days=n
    while [ "$#" -gt 0 ]; do
        _ipa_key=${1%%=*}
        case "$_inst_seen" in *" $_ipa_key "*) say_err "重复参数：$_ipa_key"; return 1 ;; esac
        _inst_seen="$_inst_seen$_ipa_key "
        case "$1" in
            --help) _inst_help=1; shift; continue ;;
            --interactive) INSTALL_MODE=interactive; shift; continue ;;
            --local) INST_LOCAL=1; shift; continue ;;
            --no-start) autostart=n; shift; continue ;;
            --no-auth) INST_NO_AUTH=1; shift; continue ;;
        esac
        case "$_ipa_key" in
            --install-dir) _ipa_var=DIR_INST ;; --branch) _ipa_var=MP_REPO_BRANCH ;;
            --source-dir) _ipa_var=_MP_SOURCE_DIR ;; --dns) _ipa_var=MP_LOCAL_DNS ;;
            --proxy) _ipa_var=MP_PROXY ;; --download-proxy) _ipa_var=INST_DOWNLOAD_PROXY; INST_DOWNLOAD_PROXY_SET=1 ;;
            --subscribe-url) _ipa_var=MP_SUBSCRIBE_URL ;; --agh-user) _ipa_var=MP_AGH_USER_NAME ;;
            --agh-password) _ipa_var=MP_AGH_PASSWORD ;; --target) _ipa_var=INST_TARGET ;;
            --ssh-port) _ipa_var=INST_SSH_PORT ;; --ssh-key) _ipa_var=INST_SSH_KEY ;;
            --ssh-auth) _ipa_var=INST_SSH_AUTH ;; --scripts-days) _ipa_var=cron_script_days ;;
            --configs-days) _ipa_var=cron_config_days ;;
            *) say_err '未知参数；请使用 --help 查看命名参数'; return 1 ;;
        esac
        case "$1" in
            *=*) _ipa_value=${1#*=}; shift ;;
            *) [ "$#" -ge 2 ] || { say_err "参数缺少值：$_ipa_key"; return 1; }
               case "$2" in --*) say_err "参数缺少值：$_ipa_key"; return 1 ;; esac
               _ipa_value=$2; shift 2 ;;
        esac
        case "$_ipa_key" in --source-dir|--target|--ssh-key)
            [ -n "$_ipa_value" ] || { say_err "$_ipa_key 不能为空"; return 1; } ;;
        esac
        eval "$_ipa_var=\$_ipa_value"
    done
    [ "$INST_LOCAL" != 1 ] || [ -z "$_MP_SOURCE_DIR" ] \
        || { say_err '--local 和 --source-dir 不能同时使用'; return 1; }
    if [ "$INST_LOCAL" = 1 ]; then
        _MP_SOURCE_DIR=${INST_ENTRY_ROOT:-}
        [ -n "$_MP_SOURCE_DIR" ] || { say_err '无法推断本地仓库；请使用 --source-dir'; return 1; }
    fi
    MP_REPO_BRANCH=${MP_REPO_BRANCH:-main}
    if [ "$INST_NO_AUTH" = 1 ]; then
        case "$_inst_seen" in *' --agh-password '*) say_err '--no-auth 与 --agh-password 不能同时使用'; return 1 ;; esac
    fi
}

inst_valid_days() {
    case "$1" in n) return 0 ;; ''|*[!0-9]*|0*) return 1 ;; esac
    [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 365 ]
}

inst_valid_proxy() {
    case "$1" in ''|http://?*|https://?*|socks5://?*|socks5h://?*) return 0 ;; *) return 1 ;; esac
}

inst_validate_basic() {
    _iv_missing=
    [ -n "$MP_SUBSCRIBE_URL" ] || _iv_missing="$_iv_missing --subscribe-url"
    [ -n "$MP_AGH_USER_NAME" ] || _iv_missing="$_iv_missing --agh-user"
    [ "$INST_NO_AUTH" = 1 ] || [ -n "$MP_AGH_PASSWORD" ] || _iv_missing="$_iv_missing --agh-password（或 --no-auth）"
    [ -z "$_iv_missing" ] || { say_err "缺少必填参数：$_iv_missing"; return 1; }
    case "$MP_SUBSCRIBE_URL" in http://?*|https://?*) ;; *) say_err '订阅 URL 必须为 http/https 地址'; return 1 ;; esac
    case "$INST_NO_AUTH:$MP_AGH_PASSWORD" in
        1:) ;;
        0:'$2a$'?*|0:'$2b$'?*|0:'$2y$'?*) ;;
        *) say_err '请选择有效的 bcrypt 密码哈希或 --no-auth'; return 1 ;;
    esac
    inst_valid_proxy "$MP_PROXY" && inst_valid_proxy "$INST_DOWNLOAD_PROXY" \
        || { say_err '不支持的代理 URL'; return 1; }
    while [ "${DIR_INST%/}" != "$DIR_INST" ]; do DIR_INST=${DIR_INST%/}; done
    case "$DIR_INST" in /*) ;; *) say_err '安装目录必须为绝对路径'; return 1 ;; esac
    case "$DIR_INST/" in *[!a-zA-Z0-9_./-]*|*'/../'*|*'/./'*|*'//'*) say_err '安装目录包含不支持的字符或路径跳转'; return 1 ;; esac
    case "$DIR_INST" in ''|/etc|/usr|/usr/local|/var|/opt|/tmp|/home|/root|/srv|/bin|/sbin|/lib|/boot|/dev|/proc|/sys|/run|/mnt|/media)
        say_err '不能将系统目录作为安装目录'; return 1 ;;
    esac
    case "$INST_TARGET" in -*|*[!a-zA-Z0-9_.:@-]*|*@|@*) say_err '无效 SSH 目标，请填写 USER@HOST 或 SSH 别名'; return 1 ;; esac
    case "$INST_SSH_PORT" in ''|*[!0-9]*) say_err '无效 SSH 端口'; return 1 ;; esac
    [ "$INST_SSH_PORT" -ge 1 ] 2>/dev/null && [ "$INST_SSH_PORT" -le 65535 ] \
        || { say_err 'SSH 端口必须为 1–65535'; return 1; }
    case "$INST_SSH_AUTH" in auto|password|key) ;; *) say_err 'SSH 认证须为 auto/password/key'; return 1 ;; esac
    [ -z "$INST_SSH_KEY" ] || [ -r "$INST_SSH_KEY" ] || { say_err 'SSH 私钥不可读'; return 1; }
    inst_valid_days "$cron_script_days" && inst_valid_days "$cron_config_days" \
        || { say_err '更新间隔须为 1–365 天'; return 1; }
    MP_REPO_BRANCH=${MP_REPO_BRANCH:-main}
}

inst_validate() {
    inst_validate_basic || return 1
    printf '%s' "$MP_REPO_BRANCH" | jq -seR '
        length > 0 and . != "@" and
        (explode | all(. as $c | . > 32 and . != 127 and ([126,94,58,63,42,91,92] | index($c) == null))) and
        (contains("..") or contains("@{") or startswith("-") or endswith(".") | not) and
        (split("/") | all(.[]; length > 0 and (startswith(".") or endswith(".lock") | not)))
    ' >/dev/null 2>&1 || { say_err '无效分支名；请填写分支名字，不是 URL'; return 1; }
    inst_validate_source
}

# === deps ===
# 安装器内部模块，由 inst.sh 加载。

inst_is_root() {
    if command -v id >/dev/null 2>&1; then
        [ "$(id -u)" = 0 ]; return $?
    fi
    while read -r _ir_key _ir_real _ir_effective _ir_rest; do
        [ "$_ir_key" != Uid: ] || { [ "$_ir_effective" = 0 ]; return $?; }
    done < /proc/self/status
    return 1
}

inst_detect_os() {
    _inst_distro=; _inst_distro_like=
    if [ -r /etc/os-release ]; then
        while IFS='=' read -r _ido_key _ido_value; do
            _ido_value=${_ido_value#\"}; _ido_value=${_ido_value%\"}
            _ido_value=${_ido_value#\'}; _ido_value=${_ido_value%\'}
            case "$_ido_key" in
                ID) _inst_distro=$_ido_value ;;
                ID_LIKE) _inst_distro_like=$_ido_value ;;
            esac
        done < /etc/os-release
    fi
    if [ -f /etc/openwrt_release ] || [ "$_inst_distro" = openwrt ]; then
        os_type=openwrt
    elif command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ]; then
        os_type=systemd
    else
        say_err '未识别 OpenWrt 或 systemd 系统'; return 1
    fi
}

inst_detect_launcher() {
    case "$(uname -s)" in
        Darwin) os_type=macos; _inst_distro=; _inst_distro_like= ;;
        Linux) inst_detect_os >/dev/null 2>&1 || os_type=linux ;;
        *) say_err '发起端只支持 Linux、macOS、OpenWrt'; return 1 ;;
    esac
}

inst_package_manager() {
    _inst_pkg_manager=
    if [ "$os_type" = openwrt ]; then
        if command -v apk >/dev/null 2>&1; then _inst_pkg_manager=apk
        elif command -v opkg >/dev/null 2>&1; then _inst_pkg_manager=opkg
        fi
    elif [ "$os_type" = macos ]; then
        command -v brew >/dev/null 2>&1 && _inst_pkg_manager=brew
    else
        case " $_inst_distro $_inst_distro_like " in
            *' debian '*|*' ubuntu '*)
                command -v apt-get >/dev/null 2>&1 && _inst_pkg_manager=apt-get ;;
        esac
    fi
    [ -n "$_inst_pkg_manager" ]
}

inst_dependency_present() {
    if [ "$1" = ssh ]; then
        case "$(ssh -V 2>&1)" in *OpenSSH*) return 0 ;; *) return 1 ;; esac
    fi
    if [ "$1" = ca-certificates ]; then
        # Debian/Ubuntu 与 OpenWrt 的系统 CA bundle；不通过联网探测证书。
        for _idp_ca in /etc/ssl/certs/ca-certificates.crt /etc/ssl/cert.pem; do
            [ ! -r "$_idp_ca" ] || [ ! -s "$_idp_ca" ] || return 0
        done
        return 1
    fi
    command -v "$1" >/dev/null 2>&1
}

inst_dependency_package() {
    if [ "$os_type" = macos ]; then
        case "$1" in sha256sum) printf '%s\n' coreutils ;; *) printf '%s\n' "$1" ;; esac
        return
    fi
    if [ "$os_type" = openwrt ]; then
        case "$1" in
            ca-certificates) printf '%s\n' ca-bundle ;;
            ip) printf '%s\n' ip-tiny ;;
            sysctl) printf '%s\n' procps-ng-sysctl ;;
            awk) printf '%s\n' gawk ;;
            find) printf '%s\n' findutils-find ;;
            gunzip|gzip) printf '%s\n' gzip ;;
            ssh) printf '%s\n' openssh-client ;;
            crontab) printf '%s\n' busybox ;;
            curl|jq|tar|sed|grep|logger|flock) printf '%s\n' "$1" ;;
            *) printf 'coreutils-%s\n' "$1" ;;
        esac
    else
        case "$1" in
            ip) printf '%s\n' iproute2 ;;
            sysctl) printf '%s\n' procps ;;
            logger) printf '%s\n' bsdutils ;;
            awk) printf '%s\n' mawk ;;
            find) printf '%s\n' findutils ;;
            gunzip|gzip) printf '%s\n' gzip ;;
            ssh) printf '%s\n' openssh-client ;;
            crontab) printf '%s\n' cron ;;
            flock) printf '%s\n' util-linux ;;
            ca-certificates|curl|jq|tar|sed|grep) printf '%s\n' "$1" ;;
            *) printf '%s\n' coreutils ;;
        esac
    fi
}

inst_apt() {
    if [ -n "$_iip_sudo" ]; then
        mp_run_download_command sudo env DEBIAN_FRONTEND=noninteractive apt-get "$@"
    else
        mp_log_command env DEBIAN_FRONTEND=noninteractive apt-get "$@"
        DEBIAN_FRONTEND=noninteractive apt-get "$@"
    fi
}

inst_install_packages() {
    say_step "安装软件包：$*"
    say_dim '使用系统软件源和包管理器代理配置；--proxy 仅用于项目资源下载'
    _iip_rc=0; _iip_sudo=
    if [ "$_inst_pkg_manager" != brew ] && ! inst_is_root; then
        command -v sudo >/dev/null 2>&1 || { say_err '补装系统依赖需要 root 或 sudo'; return 1; }
        _iip_sudo=sudo
    fi
    case "$_inst_pkg_manager" in
        apt-get)
            _iip_manual="apt-get update && apt-get install --no-install-recommends $*"
            inst_apt update </dev/null &&
                inst_apt install -y --no-install-recommends "$@" </dev/null || _iip_rc=$? ;;
        opkg)
            _iip_manual="opkg update && opkg install $*"
            mp_run_download_command $_iip_sudo opkg update </dev/null && mp_run_download_command $_iip_sudo opkg install "$@" </dev/null || _iip_rc=$? ;;
        apk)
            _iip_manual="apk update && apk add $*"
            mp_run_download_command $_iip_sudo apk update </dev/null && mp_run_download_command $_iip_sudo apk add "$@" </dev/null || _iip_rc=$? ;;
        brew) _iip_manual="brew install $*"; mp_run_download_command brew install "$@" || _iip_rc=$? ;;
        *) say_err '没有可用的软件包管理器' ; return 1 ;;
    esac
    if [ "$_iip_rc" -ne 0 ]; then
        say_err "软件包安装失败（退出码 $_iip_rc），请根据上方输出检查软件源、网络及磁盘空间"
        say_dim "手动处理后重新运行安装器：$_iip_manual"
        return 1
    fi
}

inst_require_tools() {
    if [ "${1:-}" = cron ]; then
        _irt_tools='crontab flock'
    elif [ "${1:-}" = launcher ]; then
        _irt_tools='curl jq ca-certificates tar gzip gunzip awk sed grep find cat chmod cp mv rm mkdir mktemp dirname basename readlink date sleep head sort tr wc uname id'
        [ -z "${INST_TARGET:-}" ] || _irt_tools="$_irt_tools ssh"
    else
        _irt_tools='curl jq ca-certificates tar gzip gunzip ip sysctl logger awk sed grep find
            cat chmod cp mv rm mkdir mktemp dirname basename readlink date sleep head sort tr wc ln uname id'
    fi
    if [ "${1:-}" != cron ] && ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
        _irt_tools="$_irt_tools sha256sum"
    fi
    _irt_missing=
    for _irt_tool in $_irt_tools; do
        inst_dependency_present "$_irt_tool" || _irt_missing="$_irt_missing $_irt_tool"
    done
    [ -n "$_irt_missing" ] || { say_ok '依赖检查通过'; return 0; }
    say_warn "缺少依赖：$_irt_missing"
    inst_package_manager || {
        say_err '无法自动安装：需要 apt-get、opkg/apk 或 macOS Homebrew；请手动补齐上述依赖'
        return 1
    }
    set --
    _irt_packages=' '
    for _irt_tool in $_irt_missing; do
        _irt_package=$(inst_dependency_package "$_irt_tool") || return 1
        case "$_irt_packages" in *" $_irt_package "*) continue ;; esac
        _irt_packages="$_irt_packages$_irt_package "
        set -- "$@" "$_irt_package"
    done
    inst_install_packages "$@" || return 1
    hash -r
    _irt_remaining=
    for _irt_tool in $_irt_tools; do
        inst_dependency_present "$_irt_tool" || _irt_remaining="$_irt_remaining $_irt_tool"
    done
    if [ -n "$_irt_remaining" ]; then
        say_err "安装后仍缺少依赖：$_irt_remaining；请检查 PATH、证书文件或固件是否裁剪了相关功能"
        say_dim "手动处理后重新运行安装器：$_iip_manual"
        return 1
    fi
    say_ok '缺失依赖已安装，检查通过'
}

# === source ===
# 安装器内部模块，由 inst.sh 加载。

inst_validate_source() {
    [ -n "${_MP_SOURCE_DIR:-}" ] || return 0
    _MP_SOURCE_DIR=$(CDPATH= cd -- "$_MP_SOURCE_DIR" 2>/dev/null && pwd -P) \
        || { say_err '无法读取本地仓库目录'; return 1; }
    for _ivs_rel in sh/inst.sh sh/portable.sh sh/install-lib.sh sh/install-remote.sh sh/uninstall.sh sh/env.conf sh/common.sh sh/update-scripts.sh \
        sh/update-core-config.sh sh/update-agh-config.sh sh/update-bin.sh \
        sh/update-all-configs.sh sh/update-all-configs-restart-services.sh \
        sh/update-proxy-rule.sh sh/keeplive.sh sh/setup-fake-ip-route.sh sh/run-scheduled-update.sh \
        sh/etc/init.d/agh sh/etc/init.d/proxy_core sh/etc/hotplug.d/net/99-meta-route \
        sh/etc/systemd/system/agh.service sh/etc/systemd/system/proxy_core.service \
        core/config.yaml agh/agh.yaml agh/myupstream.txt domain/gpt.txt domain/myproxylist.txt; do
        [ -f "$_MP_SOURCE_DIR/$_ivs_rel" ] && [ -r "$_MP_SOURCE_DIR/$_ivs_rel" ] \
            || { say_err "本地仓库缺少可读文件：$_ivs_rel"; return 1; }
    done
    [ -z "${INST_TARGET:-}" ] || return 0
    # 解析目标的既有父目录，避免通过符号链接或 ../ 将源目录当作安装目录。
    _ivs_parent=$DIR_INST; _ivs_tail=
    while [ ! -d "$_ivs_parent" ]; do
        _ivs_tail="/$(basename "$_ivs_parent")$_ivs_tail"
        _ivs_parent=$(dirname "$_ivs_parent")
    done
    _ivs_target=$(CDPATH= cd -- "$_ivs_parent" && pwd -P) || return 1
    _ivs_target=$(printf '%s\n' "$_ivs_target$_ivs_tail" | awk -F/ '{
        n=0; for (i=1;i<=NF;i++) { if ($i=="" || $i==".") continue;
        if ($i=="..") { if(n>0)n--; } else parts[++n]=$i; }
        for(i=1;i<=n;i++) printf "/%s", parts[i]; printf "\n";
    }')
    case "$_ivs_target/" in "$_MP_SOURCE_DIR/"*)
        say_err '安装目录不能是本地仓库目录或其子目录，请使用独立安装目录'; return 1 ;;
    esac
}

bootstrap_core_proxy() {
    [ -f "${INST_CORE_CONFIG:-$DIR_INST/core/config.yaml}" ] || return 1
    for _bcp_key in mixed-port port socks-port; do
        _bcp_port=$(awk -v key="$_bcp_key" '
            index($0, key ":") == 1 {
                v = substr($0, length(key) + 2)
                sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v)
                sub(/[[:space:]]+#.*/, "", v)
                if ((substr(v,1,1)=="\"" && substr(v,length(v),1)=="\"") ||
                    (substr(v,1,1)=="\047" && substr(v,length(v),1)=="\047")) v=substr(v,2,length(v)-2)
                print v; exit
            }' "${INST_CORE_CONFIG:-$DIR_INST/core/config.yaml}")
        case "$_bcp_port" in ''|*[!0-9]*) continue ;; esac
        [ "$_bcp_port" -ge 1 ] 2>/dev/null && [ "$_bcp_port" -le 65535 ] || continue
        case "$_bcp_key" in port) printf 'http://127.0.0.1:%s\n' "$_bcp_port" ;;
            *) printf 'socks5h://127.0.0.1:%s\n' "$_bcp_port" ;; esac
        return 0
    done
    return 1
}

bootstrap_download() {
    _bd_url=$1; _bd_dst=$2; _bd_retry_allowed=${3:-1}
    _bd_tmp=$(mktemp "$_bd_dst.tmp.XXXXXX") || return 1
    _bd_label='仓库归档'; _bd_timeout=300
    case "$_bd_url" in https://api.github.com/*) _bd_label='GitHub 分支列表'; _bd_timeout=60 ;; esac
    while ! mp_http_download "$_bd_url" "$_bd_tmp" "$(bootstrap_core_proxy 2>/dev/null || :)" \
        "${INST_DOWNLOAD_PROXY-$MP_PROXY}" "$_bd_label" "$_bd_timeout"; do
        if [ "$INSTALL_MODE" != interactive ] || [ "$_bd_retry_allowed" != 1 ]; then
            rm -f "$_bd_tmp"; return 1
        fi
        prompt_to _bd_retry Y '下载失败，重试？(Y/n)'
        case "$_bd_retry" in n|N|no|NO|No) rm -f "$_bd_tmp"; return 1 ;; esac
    done
    mv "$_bd_tmp" "$_bd_dst" || { rm -f "$_bd_tmp"; return 1; }
}

inst_fetch_branches() {
    _ifb_page=1
    : > "$_inst_tmp/branches" || return 1
    while :; do
        bootstrap_download "https://api.github.com/repos/AfxMsgBox/MyRule/branches?per_page=100&page=$_ifb_page" \
            "$_inst_tmp/branches.json" 0 || return 1
        jq -e 'type == "array" and length <= 100 and all(.[];
            (.name | type == "string") and (.name | length > 0) and
            (.name | explode | all(. >= 32 and . != 127)))' \
            "$_inst_tmp/branches.json" >/dev/null 2>&1 || return 1
        jq -r '.[].name' "$_inst_tmp/branches.json" >> "$_inst_tmp/branches" || return 1
        _ifb_count=$(jq 'length' "$_inst_tmp/branches.json") || return 1
        [ "$_ifb_count" -eq 100 ] || break
        _ifb_page=$((_ifb_page + 1))
    done
    grep -qxF main "$_inst_tmp/branches" || return 1
    { printf 'main\n'; LC_ALL=C sort -u "$_inst_tmp/branches" | sed '/^main$/d'; } \
        > "$_inst_tmp/branches.sorted"
}

inst_choose_branch() {
    while ! inst_fetch_branches; do
        rm -f "$_inst_tmp/branches" "$_inst_tmp/branches.sorted"
        say_warn '无法获取完整分支列表（网络、限流或响应格式错误）'
        prompt_to _ib_retry Y '重新获取分支列表？(Y/n)'
        case "$_ib_retry" in n|N|no|NO|No) return 1 ;; esac
    done
    printf '\n%s远端分支%s\n' "${T_B}${T_CYN}" "$T_R" >&3
    awk '{ printf "  %d) %s\n", NR, $0 }' "$_inst_tmp/branches.sorted" >&3
    while :; do
        prompt_to _ib_choice 1 '选择分支编号（回车使用 main）'
        case "$_ib_choice" in ''|*[!0-9]*) say_warn '请输入有效编号'; continue ;; esac
        MP_REPO_BRANCH=$(awk -v n="$_ib_choice" 'NR == n { print; exit }' "$_inst_tmp/branches.sorted")
        [ -n "$MP_REPO_BRANCH" ] && return 0
        say_warn '分支编号超出范围'
    done
}

# === state ===
# 安装器内部模块，由 inst.sh 加载。

inst_record_forward_state() {
    _irf_root="$DIR_SH/.install-state"
    _irf_state="$_irf_root/forward"
    [ ! -L "$_irf_root" ] && [ ! -L "$_irf_state" ] \
        || { say_err '转发恢复记录不能是符号链接'; return 1; }
    if [ -d "$_irf_state" ]; then
        [ "$(cat "$_irf_state/owner" 2>/dev/null)" = "$DIR_INST" ] \
            && [ "$(cat "$_irf_state/platform" 2>/dev/null)" = "$os_type" ] \
            && [ -f "$_irf_state/before" ] && [ -f "$_irf_state/after" ] \
            || { say_err '转发恢复记录不完整或不属于本次安装'; return 1; }
        [ -f "$_irf_state/restored" ] || return 0
        rm -rf -- "$_irf_state" || return 1
        _irf_restored=1
    else
        _irf_restored=0
    fi
    if [ "$_irf_restored" -ne 1 ] && { [ "$reinstall" -eq 1 ] || [ -e "$DIR_SH/env.local.conf" ]; }; then
        say_warn '旧安装没有转发原值记录；卸载时将保留无法确认的设置'
        return 0
    fi
    [ ! -L "$sysctl_conf" ] && { [ ! -e "$sysctl_conf" ] || [ -f "$sysctl_conf" ]; } \
        || { say_err '无法记录转发配置：目标不是普通文件'; return 1; }
    mkdir -p "$_irf_root" && chmod 700 "$_irf_root" || return 1
    _irf_tmp=$(mktemp -d "$_irf_root/.forward.XXXXXX") || return 1
    (
        umask 077
        printf '%s\n' "$DIR_INST" > "$_irf_tmp/owner" &&
        printf '%s\n' "$os_type" > "$_irf_tmp/platform" || exit 1
        if [ -f "$sysctl_conf" ]; then
            cp -p "$sysctl_conf" "$_irf_tmp/before" &&
            printf '1\n' > "$_irf_tmp/existed" || exit 1
        else
            : > "$_irf_tmp/before"
            printf '0\n' > "$_irf_tmp/existed" || exit 1
        fi
        if grep -Eq '^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=' "$_irf_tmp/before"; then
            sed -E 's/^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=.*/net.ipv4.ip_forward=1/' \
                "$_irf_tmp/before" > "$_irf_tmp/after" || exit 1
        else
            cp "$_irf_tmp/before" "$_irf_tmp/after" &&
            printf '%s\n' 'net.ipv4.ip_forward=1' >> "$_irf_tmp/after" || exit 1
        fi
        _irf_old=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null) || exit 1
        case "$_irf_old" in 0|1) ;; *) exit 1 ;; esac
        printf '%s\n' "$_irf_old" > "$_irf_tmp/runtime" || exit 1
    ) && mv "$_irf_tmp" "$_irf_state" && return 0
    rm -rf -- "$_irf_tmp"
    say_err '无法保存转发原值，停止安装'
    return 1
}

upsert_conf() {
    _uc_key=$1; _uc_val=$2; _uc_file=$3
    _uc_esc=$(printf '%s' "$_uc_val" | sed "s/'/'\\\\''/g")
    _uc_line="$_uc_key='$_uc_esc'"
    if grep -Eq "^[[:space:]]*(export[[:space:]]+)?$_uc_key=" "$_uc_file" 2>/dev/null; then
        # 通过环境传值，避免 awk -v 把值里的反斜杠再次解释。
        _MP_UPSERT_LINE="$_uc_line" awk -v k="$_uc_key" '
            BEGIN { repl = ENVIRON["_MP_UPSERT_LINE"] }
            $0 ~ "^[[:space:]]*(export[[:space:]]+)?" k "=" { print repl; next }
            { print }
        ' "$_uc_file" > "$_uc_file.tmp" && mv "$_uc_file.tmp" "$_uc_file"
    else
        printf '%s\n' "$_uc_line" >> "$_uc_file"
    fi
}

inst_enable_forward() {
    say_section "启用 IPv4 转发"
    case "$os_type" in
        systemd) sysctl_conf=/etc/sysctl.d/99-zz-myproxy.conf ;;
        openwrt) sysctl_conf=/etc/sysctl.conf ;;
    esac
    inst_record_forward_state || exit 1
    forward_persisted=0
    mkdir -p "$(dirname "$sysctl_conf")"
    if grep -Eq '^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=' "$sysctl_conf" 2>/dev/null; then
        sed -i -E 's/^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=.*/net.ipv4.ip_forward=1/' "$sysctl_conf" \
            && forward_persisted=1
    else
        printf '%s\n' 'net.ipv4.ip_forward=1' >> "$sysctl_conf" \
            && forward_persisted=1
    fi

    forward_applied=0
    forward_error=$(sysctl -w net.ipv4.ip_forward=1 2>&1) || :
    [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" = "1" ] && forward_applied=1
    if [ "$forward_applied" = "1" ] && [ "$forward_persisted" = "1" ]; then
        say_ok "net.ipv4.ip_forward = 1（已立即生效并持久化到 $sysctl_conf）"
    elif [ "$forward_applied" = "1" ]; then
        say_warn "net.ipv4.ip_forward 已立即生效，但无法写入 $sysctl_conf"
    elif [ "$forward_persisted" = "1" ]; then
        say_warn "无法立即设置 net.ipv4.ip_forward；已写入 $sysctl_conf"
        [ -n "$forward_error" ] && say_warn "sysctl: $forward_error"
        say_warn "请检查 LXC 权限或宿主机限制；重启前该功能尚未生效"
    else
        say_warn "无法设置或持久化 net.ipv4.ip_forward"
        [ -n "$forward_error" ] && say_warn "sysctl: $forward_error"
        say_warn "请检查文件系统权限、LXC 权限或宿主机限制"
    fi
    unset forward_error


}

# === schedule ===
# 安装器内部模块，由 inst.sh 加载。

install_cron_job() {
    _cj_marker=$1; _cj_days=$2; _cj_script=$3; _cj_minute=$4
    [ -r "$DIR_SH/run-scheduled-update.sh" ] || {
        say_err '所选分支缺少 run-scheduled-update.sh，无法设置定时更新'; return 1
    }
    case "$_cj_marker" in
        MyProxy:update-scripts) _cj_kind=scripts ;;
        MyProxy:update-configs) _cj_kind=configs ;;
        *) return 1 ;;
    esac
    _cj_tmp=$(mktemp) || return 1
    if LC_ALL=C crontab -l > "$_cj_tmp" 2> "$_cj_tmp.err"; then :
    elif grep -Eq 'no crontab for|can.t open.*No such file' "$_cj_tmp.err"; then : > "$_cj_tmp"
    else rm -f "$_cj_tmp" "$_cj_tmp.err"; return 1
    fi
    rm -f "$_cj_tmp.err"
    awk -v marker="$_cj_marker" -v old="$_cj_script" -v runner="$DIR_SH/run-scheduled-update.sh" -v kind="$_cj_kind" '
        /^[ \t]*#/ { print; next }
        {
            n=split($0,a,/[ \t]+/)
            if (a[n]==marker && a[n-1]=="#") {
                if (a[n-3]=="sh" && (a[n-2]==old || a[n-2]=="\047" old "\047")) next
                if (a[n-5]=="sh" && (a[n-4]==runner || a[n-4]=="\047" runner "\047") &&
                    a[n-3]==kind && a[n-2] ~ /^[0-9]+$/) next
            }
            print
        }
    ' "$_cj_tmp" > "$_cj_tmp.new" || { rm -f "$_cj_tmp" "$_cj_tmp.new"; return 1; }
    printf "%s 3 * * * sh '%s/run-scheduled-update.sh' %s %s # %s\n" \
        "$_cj_minute" "$DIR_SH" "$_cj_kind" "$_cj_days" "$_cj_marker" >> "$_cj_tmp.new"
    # 从启用日开始计算首次间隔；已有成功记录保留。
    mkdir -p "$DIR_SH/.schedule" || { rm -f "$_cj_tmp" "$_cj_tmp.new"; return 1; }
    if [ ! -f "$DIR_SH/.schedule/$_cj_kind.last" ]; then
        _cj_now=$(date +%s) || { rm -f "$_cj_tmp" "$_cj_tmp.new"; return 1; }
        printf '%s\n' "$((_cj_now / 86400))" > "$DIR_SH/.schedule/$_cj_kind.last" \
            || { rm -f "$_cj_tmp" "$_cj_tmp.new"; return 1; }
    fi
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
            "输入间隔天数 1-365，回车默认 3 天；输入 n 跳过设置"
        eval "_pcd_value=\$$_pcd_var"
        case "$_pcd_value" in
            n|N|no|NO|No) return 1 ;;
            ''|*[!0-9]*|0*) say_err "      请输入 1-365，或输入 n 跳过。" ;;
            *)
                if [ "$_pcd_value" -ge 1 ] 2>/dev/null && [ "$_pcd_value" -le 365 ]; then
                    return 0
                fi
                say_err "      间隔天数必须在 1-365 之间。"
                ;;
        esac
    done
}

inst_apply_schedule() {
    _ias_changed=0
    if [ "$cron_script_days" != n ]; then
        install_cron_job MyProxy:update-scripts "$cron_script_days" "$DIR_SH/update-scripts.sh" 0 || return 1
        say_ok "脚本：每隔 $cron_script_days 天更新"
        _ias_changed=1
    fi
    if [ "$cron_config_days" != n ]; then
        install_cron_job MyProxy:update-configs "$cron_config_days" "$DIR_SH/update-all-configs-restart-services.sh" 5 || return 1
        say_ok "配置：每隔 $cron_config_days 天更新"
        _ias_changed=1
    fi
    if [ "$_ias_changed" = 1 ] && [ "$os_type" = openwrt ]; then
        /etc/init.d/cron enable && /etc/init.d/cron restart || return 1
    fi
}

# === bundle ===
# 安装包只包含仓库快照、资源缓存和参数；绝不执行下载的目标二进制。
INST_CONFIG_KEYS='DIR_INST MP_REPO_BRANCH MP_PROXY MP_SUBSCRIBE_URL MP_AGH_USER_NAME MP_AGH_PASSWORD MP_LOCAL_DNS autostart cron_script_days cron_config_days INST_TARGET_OS INST_TARGET_ARCH INST_NO_AUTH'

inst_snapshot() (
    _is_dst=$1
    if [ -n "$_MP_SOURCE_DIR" ]; then
        _is_src=$_MP_SOURCE_DIR
    else
        _is_branch=$(printf '%s' "$MP_REPO_BRANCH" | jq -sRr '@uri') || exit 1
        if [ "$_is_branch" = "${_INST_BOOT_BRANCH:-}" ] && [ -d "${_INST_BOOT_REPO:-}/sh" ]; then
            _is_src=$_INST_BOOT_REPO
        else
        bootstrap_download "https://codeload.github.com/AfxMsgBox/MyRule/tar.gz/refs/heads/$_is_branch" "$_inst_tmp/repo.tgz" || exit 1
        mkdir "$_inst_tmp/unpack" && tar -xzf "$_inst_tmp/repo.tgz" -C "$_inst_tmp/unpack" || exit 1
        set -- "$_inst_tmp/unpack"/*
        [ "$#" -eq 1 ] && [ -d "$1/sh" ] || exit 1
        _is_src=$1
        fi
    fi
    # macOS /tmp 常为 /private/tmp 的链接；目录和文件必须使用同一种真实路径。
    _is_src=$(CDPATH= cd -- "$_is_src" 2>/dev/null && pwd -P) \
        || { say_err '无法解析仓库源目录'; exit 1; }
    mkdir -p "$_is_dst" || exit 1
    (cd "$_is_src" && find sh domain -type f -print) > "$_inst_tmp/source-files" || exit 1
    printf '%s\n' core/config.yaml agh/agh.yaml agh/myupstream.txt >> "$_inst_tmp/source-files"
    while IFS= read -r _is_rel; do
        case "$_is_rel" in sh/env.local.conf|sh/.install-state/*|sh/.schedule/*) continue ;; esac
        case "$_is_rel" in *[!a-zA-Z0-9_./-]*|*/../*|*/./*|*//*|/*) echo '仓库路径不受支持' >&2; exit 1 ;; esac
        _is_real=$(mp_realpath "$_is_src/$_is_rel") \
            || { say_err "无法解析仓库文件：$_is_rel"; exit 1; }
        case "$_is_real" in "$_is_src"/*) ;; *) say_err "仓库文件超出源目录：$_is_rel"; exit 1 ;; esac
        [ -f "$_is_real" ] && mkdir -p "$_is_dst/$(dirname "$_is_rel")" && cp -p "$_is_real" "$_is_dst/$_is_rel" \
            || { say_err "无法复制仓库文件：$_is_rel"; exit 1; }
    done < "$_inst_tmp/source-files"
    _MP_SOURCE_DIR=$_is_dst; INST_TARGET=bundle
    inst_validate_source
)

inst_manifest() (
    cd "$1" || exit 1
    find repo resources -type f -print > files || exit 1
    printf '%s\n' config.json >> files
    LC_ALL=C sort files > files.sorted || exit 1
    : > manifest
    while IFS= read -r _im_path; do
        case "$_im_path" in *[!a-zA-Z0-9_./-]*|*/../*|*/./*|*//*|/*) exit 1 ;; esac
        _im_hash=$(mp_sha256 < "$_im_path") || exit 1
        printf '%s  %s\n' "$_im_hash" "$_im_path" >> manifest || exit 1
    done < files.sorted
    rm files files.sorted
)

inst_verify_bundle() (
    cd "$1" || exit 1
    [ -f manifest ] && [ ! -L manifest ] || exit 1
    # 不接受符号链接或特殊文件；核对清单完整性与内容。
    [ -z "$(find . ! -type f ! -type d -print)" ] || exit 1
    _ivb_actual=$(find . -type f ! -name manifest | sed 's|^./||' | LC_ALL=C sort)
    _ivb_list=$(sed -n 's/^[0-9a-f]*  //p' manifest | LC_ALL=C sort)
    [ "$_ivb_actual" = "$_ivb_list" ] || exit 1
    while read -r _ivb_hash _ivb_path; do
        case "$_ivb_path" in *[!a-zA-Z0-9_./-]*|*/../*|*/./*|*//*|/*|'') exit 1 ;; esac
        [ "${#_ivb_hash}" = 64 ] && [ "$(mp_sha256 < "$_ivb_path")" = "$_ivb_hash" ] || exit 1
    done < manifest
)

inst_save_config() {
    for _isc_key in $INST_CONFIG_KEYS; do export "$_isc_key"; done
    jq -n --arg keys "$INST_CONFIG_KEYS" 'env as $e | reduce ($keys|split(" ")[]) as $k ({}; .[$k]=$e[$k])' > "$1"
}

inst_load_config() {
    # 部分 OpenWrt jq 对 contains("\u0000") 的判断错误，按字符码检查 NUL。
    jq -e --arg keys "$INST_CONFIG_KEYS" 'type == "object" and (keys|sort)==($keys|split(" ")|sort) and all(.[]; type=="string" and (explode | index(0) == null))' "$1" >/dev/null 2>&1 \
        || { say_err '安装包参数校验失败：需要完整的字符串字段，且不能含空字符'; return 1; }
    for _ilc_key in $INST_CONFIG_KEYS; do
        _ilc_value=$(jq -r --arg key "$_ilc_key" '.[$key]' "$1") || return 1
        eval "$_ilc_key=\$_ilc_value"
        export "$_ilc_key"
    done
}

inst_prepare() (
    _ip_bundle=$1
    umask 077
    mkdir -p "$_ip_bundle/resources" || exit 1
    say_section '准备仓库快照'
    inst_snapshot "$_ip_bundle/repo" || exit 1
    inst_save_config "$_ip_bundle/config.json" || exit 1
    say_section '下载目标机所需资源'
    MP_INST_DIR="$_inst_tmp/prepare"
    mkdir -p "$MP_INST_DIR" && cp -R "$_ip_bundle/repo/sh" "$MP_INST_DIR/sh" || exit 1
    _MP_SOURCE_DIR="$_ip_bundle/repo"; _MP_CACHE_WRITE="$_ip_bundle/resources"
    _MP_TARGET_ARCH=$INST_TARGET_ARCH; _MP_DOWNLOAD_CORE_CONFIG=$INST_CORE_CONFIG
    MP_PROXY=$INST_DOWNLOAD_PROXY
    export MP_INST_DIR MP_REPO_BRANCH MP_PROXY MP_LOCAL_DNS MP_SUBSCRIBE_URL MP_AGH_USER_NAME MP_AGH_PASSWORD
    export _MP_SOURCE_DIR _MP_CACHE_WRITE _MP_TARGET_ARCH _MP_DOWNLOAD_CORE_CONFIG
    . "$MP_INST_DIR/sh/common.sh" || exit 1
    sh "$MP_INST_DIR/sh/update-core-config.sh" &&
        sh "$MP_INST_DIR/sh/update-bin.sh" &&
        mp_prepare_agh_config "$MP_AGH_DIR/agh.yaml.pending" &&
        sh "$MP_INST_DIR/sh/update-agh-config.sh" || exit 1
    inst_manifest "$_ip_bundle" && inst_verify_bundle "$_ip_bundle" || exit 1
    say_ok '安装包资源齐全，校验通过'
)

# === interactive ===
inst_collect_inputs() {
    say_section 'MyRule 安装向导'
    printf '  1) 本机安装（在线下载）\n  2) SSH 安装（在线下载）\n  3) SSH 安装（使用本地仓库）\n  4) 本机安装（使用本地仓库）\n' >&3
    _ici_default=1
    [ -z "$INST_TARGET" ] || _ici_default=2
    if [ -n "$_MP_SOURCE_DIR" ]; then
        _ici_default=4; [ -z "$INST_TARGET" ] || _ici_default=3
    fi
    while :; do
        prompt_to _ici_mode "$_ici_default" '选择安装方式'
        case "$_ici_mode" in 1|2|3|4) break ;; *) say_warn '请输入 1–4' ;; esac
    done
    case "$_ici_mode" in
        2|3)
            prompt_to INST_TARGET "$INST_TARGET" 'SSH 目标（用户名@主机）'
            prompt_to INST_SSH_PORT "$INST_SSH_PORT" 'SSH 端口'
            prompt_to INST_SSH_AUTH "$INST_SSH_AUTH" 'SSH 认证（auto / password / key）' 'auto 使用 SSH 配置、agent 或密码提示'
            prompt_to INST_SSH_KEY "$INST_SSH_KEY" '私钥路径（空值使用 SSH 默认密钥）' ;;
        *) INST_TARGET= ;;
    esac
    case "$_ici_mode" in
        3|4)
            prompt_to _MP_SOURCE_DIR "${_MP_SOURCE_DIR:-${INST_ENTRY_ROOT:-}}" '本地仓库根目录（按 inst.sh 位置自动识别）'
            [ -n "$_MP_SOURCE_DIR" ] || { say_err '没有找到本地仓库，请指定目录'; return 1; } ;;
        *) _MP_SOURCE_DIR= ;;
    esac
    prompt_to DIR_INST "$DIR_INST" '目标安装目录'
    prompt_to MP_PROXY "$MP_PROXY" '目标机外部后备代理（空值不设置；Core 仍优先）'
    if [ -n "$INST_TARGET" ]; then
        prompt_to INST_DOWNLOAD_PROXY "$INST_DOWNLOAD_PROXY" '发起端下载代理（仅本次使用，空值不设置）'
    else
        [ "$INST_DOWNLOAD_PROXY_SET" = 1 ] || INST_DOWNLOAD_PROXY=$MP_PROXY
    fi
    INST_DOWNLOAD_PROXY_SET=1
    inst_set_download_context
    [ -z "$_MP_SOURCE_DIR" ] || say_dim '本地仓库保持原文件；所选分支用于后续 GitHub 更新'
    if [ -n "${_INST_BOOT_SELECTED:-}" ] && [ -d "${_INST_BOOT_REPO:-}/sh" ]; then
        MP_REPO_BRANCH=$_INST_BOOT_SELECTED
        say_dim "GitHub 分支：$MP_REPO_BRANCH（已在启动时选择）"
    else
        inst_choose_branch || return 1
    fi
    prompt_to MP_SUBSCRIBE_URL "$MP_SUBSCRIBE_URL" '节点订阅 URL（可见输入）'
    inst_choose_auth || return 1
    inst_prompt_dns
    prompt_to autostart "$autostart" '立即启用配置并启动/重启服务？(Y/n)'
    case "$autostart" in Y|y|yes|YES|Yes) autostart=Y ;; n|N|no|NO|No) autostart=n ;; *) say_err '请选择 Y 或 n'; return 1 ;; esac
    prompt_cron_days cron_script_days '每隔几天更新脚本？' || cron_script_days=n
    prompt_cron_days cron_config_days '每隔几天更新配置？' || cron_config_days=n
}

inst_prompt_dns() {
    prompt_to MP_LOCAL_DNS "$MP_LOCAL_DNS" '直连 DNS，多个地址以空格分隔；输入 - 使用系统 DNS'
    [ "$MP_LOCAL_DNS" != - ] || MP_LOCAL_DNS=
    return 0
}

inst_choose_auth() {
    _ica_default=n
    [ -z "$MP_AGH_PASSWORD" ] || _ica_default=y
    while :; do
        prompt_to _ica_answer "$_ica_default" '是否设置 AGH 登录密码？(y/N)' \
            '不设置则免登录；能访问管理端口的人都可以修改配置'
        case "$_ica_answer" in
            y|Y|yes|YES|Yes)
                INST_NO_AUTH=0
                prompt_to MP_AGH_USER_NAME "${MP_AGH_USER_NAME:-admin}" 'AGH 管理员用户名'
                prompt_to MP_AGH_PASSWORD "$MP_AGH_PASSWORD" 'AGH 密码 bcrypt 哈希（可见输入）'
                return 0 ;;
            n|N|no|NO|No)
                INST_NO_AUTH=1; MP_AGH_PASSWORD=
                say_dim 'AGH 将使用免登录模式'
                return 0 ;;
            *) say_warn '请输入 y 或 n' ;;
        esac
    done
}

# === apply ===
# 内部入口：仅接受已准备的安装包路径，不联网下载项目资源。
inst_apply() (
    inst_is_root || { say_err '目标安装需要 root 权限'; exit 1; }
    _ia_bundle=$(CDPATH= cd "$1" && pwd -P) || exit 1
    inst_verify_bundle "$_ia_bundle" || { say_err '安装包校验失败，未修改安装目录'; exit 1; }
    inst_parse_args --no-start || exit 1
    inst_load_config "$_ia_bundle/config.json" && inst_validate_basic || exit 1
    inst_detect_os || exit 1
    [ "$os_type" = "$INST_TARGET_OS" ] && [ "$(uname -m)" = "$INST_TARGET_ARCH" ] \
        || { say_err '安装包与目标系统或架构不一致'; exit 1; }
    inst_require_tools && mp_require_tun || exit 1
    if [ "$cron_script_days" != n ] || [ "$cron_config_days" != n ]; then inst_require_tools cron || exit 1; fi
    DIR_SH="$DIR_INST/sh"; DIR_CORE="$DIR_INST/core"; DIR_AGH="$DIR_INST/agh"
    for _ia_dir in "$DIR_INST" "$DIR_SH" "$DIR_CORE" "$DIR_AGH"; do
        [ ! -L "$_ia_dir" ] || { say_err '安装目录不能是符号链接'; exit 1; }
    done
    reinstall=0
    if [ -e "$DIR_CORE/config.yaml" ] || [ -e "$DIR_AGH/agh.yaml" ] || [ -e "$DIR_AGH/dns.conf" ]; then reinstall=1; fi
    mkdir -p "$DIR_SH/etc" "$DIR_CORE" "$DIR_AGH" || exit 1
    inst_enable_forward || exit 1
    _MP_SOURCE_DIR="$_ia_bundle/repo"; _MP_RESOURCE_DIR="$_ia_bundle/resources"
    _MP_NONINTERACTIVE=1; _MP_INSTALL_OUTPUT=1
    export _MP_SOURCE_DIR _MP_RESOURCE_DIR _MP_NONINTERACTIVE _MP_INSTALL_OUTPUT
    inst_bootstrap_file() { cp "$_MP_SOURCE_DIR/sh/$1" "$DIR_SH/$1"; }
    say_section "写入 env.local.conf"
    say_dim "$DIR_SH/env.local.conf"
    [ -f "$DIR_SH/env.local.conf" ] || { : > "$DIR_SH/env.local.conf" || exit 1; }
    # 旧 URL 不再兼容；保留其它用户自定义行。
    awk '!/^[[:space:]]*(export[[:space:]]+)?MP_REPO_RAW_URL=/' "$DIR_SH/env.local.conf" > "$DIR_SH/env.local.conf.tmp" \
        && mv "$DIR_SH/env.local.conf.tmp" "$DIR_SH/env.local.conf" || exit 1
    kv_keys="MP_INST_DIR MP_REPO_BRANCH MP_PROXY MP_SUBSCRIBE_URL MP_AGH_USER_NAME MP_AGH_PASSWORD MP_LOCAL_DNS"
    for kv_key in $kv_keys; do
        eval "kv_val=\$$kv_key"
        case "$kv_key" in
            MP_INST_DIR) kv_val="$DIR_INST" ;;
        esac
        upsert_conf "$kv_key" "$kv_val" "$DIR_SH/env.local.conf" \
            || { say_err "保存 $kv_key 失败"; exit 1; }
    done
    chmod 0600 "$DIR_SH/env.local.conf" || exit 1


    # === Bootstrap：已完成参数收集和校验 ===
    say_section "Bootstrap"
    say_step "准备 env.conf / common.sh"
    inst_bootstrap_file portable.sh && inst_bootstrap_file env.conf || { say_err '获取 env.conf 失败，请检查文件来源'; exit 1; }
    inst_bootstrap_file common.sh || { say_err '获取 common.sh 失败，请检查文件来源'; exit 1; }

    export MP_INST_DIR="$DIR_INST"            # 显式声明根（init.d/$0 不可靠）
    . "$DIR_SH/common.sh" || exit 1           # 加载公共函数

    # === 从在线 tarball 或本地目录同步 sh/ 整树 ===
    # 覆盖刚 bootstrap 的 2 个文件无害；同步时排除 env.local.conf
    say_step "同步仓库 sh/ 整树"
    mp_fetch_repo_sh "$DIR_SH" || { say_err "同步仓库脚本失败"; exit 1; }

    # === sh/etc 路径占位替换（是否 cp 到 /etc 由后面 autostart 决定） ===
    etc_rels=$(mp_etc_rels)
    say_step "sh/etc 路径替换 /etc/proxy → $DIR_INST"
    mp_sync_etc_files never || { say_err "处理 sh/etc 失败"; exit 1; }

    # === 三份配置先暂存，重装下载期间保留原正式配置和本机代理 ===
    core_pending="$MP_CORE_DIR/config.yaml.pending"
    agh_pending="$MP_AGH_DIR/agh.yaml.pending"
    dns_pending="$MP_AGH_DIR/dns.conf.pending"
    rm -f "$core_pending" "$agh_pending" "$dns_pending" || exit 1
    say_section "生成 Core 配置"
    sh "$DIR_SH/update-core-config.sh" "$core_pending" \
        || { say_err "Core 配置或 provider 下载失败，停止安装"; exit 1; }

    # === 下载内核二进制（mihomo / AdGuardHome）===
    # metacubexd 目录从 pending 配置读取，下载代理仍从旧正式配置读取。
    say_section "下载内核二进制"
    sh "$DIR_SH/update-bin.sh" "$core_pending" \
        || { say_err "二进制或 UI 下载失败，停止安装"; exit 1; }

    # === 下载并渲染 agh.yaml，同时预下载其中的 filters ===
    say_section "渲染 AGH 配置"
    say_dim "$agh_pending"
    say_step "下载模板并预下载 AGH filters"
    mp_prepare_agh_config "$agh_pending" "$core_pending" \
        || { say_err "AGH 配置或 filter 下载失败，停止安装"; exit 1; }
    say_ok "agh.yaml 已暂存"

    # === 生成 AGH dns.conf；Core DNS 地址从 config.yaml 读取 ===
    say_section "生成 AGH dns.conf"
    sh "$DIR_SH/update-agh-config.sh" "$core_pending" "$dns_pending" \
        || { say_err "AGH dns.conf 生成失败，停止安装"; exit 1; }

    # === [7/9] 自启动询问 ===
    # Y：安装服务文件；首次安装 enable+start，重装先停 AGH 再切换并 enable+restart。
    # n：不安装或启用服务文件；前面的 IPv4 转发配置已经写入 /etc。
    unset _MP_SOURCE_DIR _MP_RESOURCE_DIR _MP_TARGET_ARCH _MP_DOWNLOAD_CORE_CONFIG _MP_CACHE_WRITE
    case "$autostart" in
        n|N|no|NO|No)
            say_section "已跳过自启动"
            if [ "$reinstall" -eq 1 ]; then
                say_ok "原正式配置保持不变；新配置保留在 config.yaml.pending、agh.yaml.pending、dns.conf.pending"
                say_dim "重跑 inst.sh 并选 Y 可重新下载并切换；应用本次已下载配置可执行："
                say_dim "  export MP_INST_DIR='$DIR_INST'"
                say_dim '  . "$MP_INST_DIR/sh/common.sh"'
                say_dim '  mp_sync_etc_files always && mp_activate_configs enable_restart "$MP_CORE_DIR/config.yaml.pending" "$MP_AGH_DIR/dns.conf.pending"'
            else
                mp_commit_pending_configs "$core_pending" "$dns_pending" \
                    || { say_err "首次安装配置写入失败"; exit 1; }
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
            fi
            ;;
        *)
            say_section "安装服务文件到 /etc 并启动"
            mp_sync_etc_files always \
                || { say_err "安装服务文件失败"; exit 1; }
            activation_op=enable_start
            [ "$reinstall" -eq 0 ] || activation_op=enable_restart
            mp_activate_configs "$activation_op" "$core_pending" "$dns_pending" \
                || { say_err "配置或服务切换失败，停止安装"; exit 1; }
            ;;
    esac

    inst_apply_schedule || exit 1
    inst_print_result
)

# 只有部署、配置切换及定时任务均成功后才输出结果。
inst_print_result() {
    say_section "安装结果"
    case "$autostart" in
        n|N|no|NO|No)
            say_ok '文件部署成功；按选择未启动或重启服务'
            say_dim '本次未检查服务运行状态，请按上方命令启用。'
            ;;
        *)
            say_ok '安装成功：Core 和 AGH 已启动'
            say_dim 'Core API、TUN 接口和 fake-ip 路由检查通过。'
            ;;
    esac
    printf '%s  %s\n' "${C_B}安装目录${C_R}" "$DIR_INST"
    printf '%s  %s\n' "${C_B}仓库分支${C_R}" "$MP_REPO_BRANCH"
    printf '%s  %s%s%s\n' "${C_B}AGH Web ${C_R}" "${C_CYN}" "http://<本机IP>:180" "${C_R}"
    if [ "$INST_NO_AUTH" = 1 ]; then say_dim '认证：免登录'
    else say_dim "认证：用户名 $MP_AGH_USER_NAME"; fi
    case "$os_type" in
        openwrt) printf '%s  %slogread -e MyProxy -f%s\n' "${C_B}日志    ${C_R}" "${C_D}" "${C_R}" ;;
        systemd) printf '%s  %sjournalctl -t MyProxy -f%s\n' "${C_B}日志    ${C_R}" "${C_D}" "${C_R}" ;;
    esac
    printf '\n%s\n' "${C_B}日常维护命令（在安装设备上执行）${C_R}"
    say_dim "  脚本:   sh $DIR_SH/update-scripts.sh"
    say_dim "  配置:   sh $DIR_SH/update-all-configs-restart-services.sh"
    say_dim "  二进制: sh $DIR_SH/update-bin.sh"
}

# === 主流程 ===
inst_set_download_context() {
    if [ -n "$INST_TARGET" ]; then
        INST_CORE_CONFIG=/etc/proxy/core/config.yaml
    else
        INST_CORE_CONFIG=$DIR_INST/core/config.yaml
        [ "$INST_DOWNLOAD_PROXY_SET" = 1 ] || INST_DOWNLOAD_PROXY=$MP_PROXY
    fi
}

inst_main() {
    inst_colors
    # 内部 apply 仅由已校验传输包的前置入口或本机流程调用。
    if [ "${1:-}" = --apply ] && [ "$#" = 2 ]; then inst_apply "$2"; return $?; fi
    inst_parse_args "$@" || return 1
    [ "$_inst_help" != 1 ] || { inst_usage; return 0; }
    if [ "$INSTALL_MODE" = interactive ]; then
        ( : <>/dev/tty ) 2>/dev/null || { say_err '无参数安装需要交互终端；自动化请提供命名参数'; return 1; }
        exec 3<>/dev/tty; inst_colors
    else
        inst_validate_basic || return 1
    fi
    inst_detect_launcher || return 1
    say_section '检查发起端依赖'
    inst_require_tools launcher || return 1
    umask 077
    _inst_tmp=$(mktemp -d /tmp/myrule.XXXXXXXX) || return 1
    trap inst_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    unset _MP_RESOURCE_DIR _MP_CACHE_WRITE _MP_TARGET_ARCH _MP_DOWNLOAD_CORE_CONFIG
    _MP_NONINTERACTIVE=1; _MP_INSTALL_OUTPUT=1
    export _MP_NONINTERACTIVE _MP_INSTALL_OUTPUT
    inst_set_download_context
    if [ "$INSTALL_MODE" = interactive ]; then inst_collect_inputs || return 1; fi
    inst_validate || return 1
    inst_set_download_context
    if [ -n "$INST_TARGET" ]; then
        inst_require_tools launcher && inst_probe_target || return 1
    else
        inst_is_root || { say_err '本机安装需要 root；请使用 sudo sh inst.sh'; return 1; }
        inst_detect_os && mp_require_tun || return 1
        INST_TARGET_OS=$os_type; INST_TARGET_ARCH=$(uname -m)
    fi
    say_section '安装概览'
    printf '  目标：%s\n  平台：%s / %s\n  目录：%s\n  分支：%s\n' "${INST_TARGET:-本机}" "$INST_TARGET_OS" "$INST_TARGET_ARCH" "$DIR_INST" "$MP_REPO_BRANCH"
    say_dim "仓库来源：${_MP_SOURCE_DIR:-GitHub}"
    inst_prepare "$_inst_tmp/bundle" || { say_err '准备失败，未修改目标安装文件'; return 1; }
    if [ -n "$INST_TARGET" ]; then
        inst_deploy_remote "$_inst_tmp/bundle"
    else
        sh "$_inst_tmp/bundle/repo/sh/install-lib.sh" --installer-run --apply "$_inst_tmp/bundle"
    fi
}

if [ "${1:-}" = --installer-run ]; then
    shift
    INST_LIB=$(CDPATH= cd "$(dirname "$0")" && pwd -P) || exit 1
    . "$INST_LIB/portable.sh" || exit 1
    . "$INST_LIB/install-remote.sh" || exit 1
    inst_main "$@"
fi
