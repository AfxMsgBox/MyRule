#!/bin/sh
# 零参数交互安装；有参数静默安装。支持在线仓库或本地仓库目录。
# wget .../main/sh/inst.sh | sh
# sh inst.sh --subscribe-url 'https://example.com/sub' --agh-user admin --agh-password '$2a$...'

inst_usage() {
    cat <<'USAGE'
用法：sh inst.sh [命名参数]
无参数：交互安装（需要终端）。有参数：静默安装，不修改 cron。
必填：
  --subscribe-url URL      节点订阅 URL
  --agh-user USER          AGH 管理员用户名
  --agh-password HASH      bcrypt 哈希（用单引号包裹）
可选：
  --install-dir DIR        默认 /etc/proxy
  --source-dir DIR         从本地仓库目录读取脚本、配置、规则；外部资源仍联网
  --branch NAME            分支名字；省略或空值为 main，不接受 URL
  --dns 'DNS1 DNS2'         默认 '223.5.5.5 119.29.29.29'；空值读取系统 DNS
  --proxy URL              外部后备代理；省略或空值则只尝试 Core 和直连
  --help                   仅显示帮助
支持 --参数=值；必填项不能由环境变量或旧配置补齐。缺失依赖会提示并自动安装。
软件包使用系统软件源及包管理器代理配置，不使用 --proxy。
USAGE
}

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

# 参数只映射到固定变量，不 eval 用户输入；在任何安装写入之前解析。
inst_parse_args() {
    INSTALL_MODE=interactive; _inst_help=0; _MP_SOURCE_DIR=
    [ "$#" -eq 0 ] && return 0
    INSTALL_MODE=silent
    if [ "$#" -eq 1 ] && [ "$1" = --help ]; then _inst_help=1; return 0; fi
    DIR_INST=/etc/proxy; MP_REPO_BRANCH=main; MP_LOCAL_DNS='223.5.5.5 119.29.29.29'
    MP_PROXY=; MP_SUBSCRIBE_URL=; MP_AGH_USER_NAME=; MP_AGH_PASSWORD=
    _ipa_seen=' '
    while [ "$#" -gt 0 ]; do
        _ipa_key=${1%%=*}
        case "$_ipa_key" in
            --install-dir|--source-dir|--branch|--dns|--proxy|--subscribe-url|--agh-user|--agh-password) ;;
            *) say_err '未知参数；请使用 --help 查看命名参数'; return 1 ;;
        esac
        case "$_ipa_seen" in *" $_ipa_key "*) say_err "重复参数：$_ipa_key"; return 1 ;; esac
        _ipa_seen="$_ipa_seen$_ipa_key "
        case "$1" in
            *=*) _ipa_value=${1#*=}; shift ;;
            *)
                [ "$#" -ge 2 ] || { say_err "参数缺少值：$_ipa_key"; return 1; }
                case "$2" in --*) say_err "参数缺少值：$_ipa_key"; return 1 ;; esac
                _ipa_value=$2; shift 2 ;;
        esac
        case "$_ipa_key" in
            --install-dir) DIR_INST=$_ipa_value ;;
            --source-dir)
                [ -n "$_ipa_value" ] || { say_err '--source-dir 不能为空'; return 1; }
                _MP_SOURCE_DIR=$_ipa_value ;;
            --branch) MP_REPO_BRANCH=${_ipa_value:-main} ;;
            --dns) MP_LOCAL_DNS=$_ipa_value ;;
            --proxy) MP_PROXY=$_ipa_value ;;
            --subscribe-url) MP_SUBSCRIBE_URL=$_ipa_value ;;
            --agh-user) MP_AGH_USER_NAME=$_ipa_value ;;
            --agh-password) MP_AGH_PASSWORD=$_ipa_value ;;
        esac
    done
}

# 本地目录必须包含安装所需仓库文件；失败时不混用远端版本。
inst_validate_source() {
    [ -n "${_MP_SOURCE_DIR:-}" ] || return 0
    _MP_SOURCE_DIR=$(CDPATH= cd -- "$_MP_SOURCE_DIR" 2>/dev/null && pwd -P) \
        || { say_err '无法读取本地仓库目录'; return 1; }
    for _ivs_rel in sh/inst.sh sh/uninstall.sh sh/env.conf sh/common.sh sh/update-scripts.sh \
        sh/update-core-config.sh sh/update-agh-config.sh sh/update-bin.sh \
        sh/update-all-configs.sh sh/update-all-configs-restart-services.sh \
        sh/update-proxy-rule.sh sh/keeplive.sh sh/setup-fake-ip-route.sh sh/run-scheduled-update.sh \
        sh/etc/init.d/agh sh/etc/init.d/proxy_core sh/etc/hotplug.d/net/99-meta-route \
        sh/etc/systemd/system/agh.service sh/etc/systemd/system/proxy_core.service \
        core/config.yaml agh/agh.yaml agh/myupstream.txt domain/gpt.txt domain/myproxylist.txt; do
        [ -f "$_MP_SOURCE_DIR/$_ivs_rel" ] && [ -r "$_MP_SOURCE_DIR/$_ivs_rel" ] \
            || { say_err "本地仓库缺少可读文件：$_ivs_rel"; return 1; }
    done
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

# 自举检查只能依赖 shell 内建；curl、jq、grep 等都可能尚未安装。
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

inst_package_manager() {
    _inst_pkg_manager=
    if [ "$os_type" = openwrt ]; then
        if command -v apk >/dev/null 2>&1; then _inst_pkg_manager=apk
        elif command -v opkg >/dev/null 2>&1; then _inst_pkg_manager=opkg
        fi
    else
        case " $_inst_distro $_inst_distro_like " in
            *' debian '*|*' ubuntu '*)
                command -v apt-get >/dev/null 2>&1 && _inst_pkg_manager=apt-get ;;
        esac
    fi
    [ -n "$_inst_pkg_manager" ]
}

inst_dependency_present() {
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
    if [ "$os_type" = openwrt ]; then
        case "$1" in
            ca-certificates) printf '%s\n' ca-bundle ;;
            ip) printf '%s\n' ip-tiny ;;
            sysctl) printf '%s\n' procps-ng-sysctl ;;
            awk) printf '%s\n' gawk ;;
            find) printf '%s\n' findutils-find ;;
            gunzip|gzip) printf '%s\n' gzip ;;
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
            crontab) printf '%s\n' cron ;;
            flock) printf '%s\n' util-linux ;;
            ca-certificates|curl|jq|tar|sed|grep) printf '%s\n' "$1" ;;
            *) printf '%s\n' coreutils ;;
        esac
    fi
}

# 软件包来自系统软件源，遵循包管理器自身的网络配置；不依赖下载函数。
inst_install_packages() {
    say_step "安装软件包：$*"
    say_dim '使用系统软件源和包管理器代理配置；--proxy 仅用于项目资源下载'
    _iip_rc=0
    case "$_inst_pkg_manager" in
        apt-get)
            _iip_manual="apt-get update && apt-get install --no-install-recommends $*"
            DEBIAN_FRONTEND=noninteractive apt-get update </dev/null &&
                DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" </dev/null || _iip_rc=$? ;;
        opkg)
            _iip_manual="opkg update && opkg install $*"
            opkg update </dev/null && opkg install "$@" </dev/null || _iip_rc=$? ;;
        apk)
            _iip_manual="apk update && apk add $*"
            apk update </dev/null && apk add "$@" </dev/null || _iip_rc=$? ;;
        *) say_err '没有可用的软件包管理器'; return 1 ;;
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
    else
        _irt_tools='curl jq ca-certificates tar gzip gunzip ip sysctl logger awk sed grep find
            cat chmod cp mv rm mkdir mktemp dirname basename readlink date sleep head sort tr wc ln uname id'
    fi
    _irt_missing=
    for _irt_tool in $_irt_tools; do
        inst_dependency_present "$_irt_tool" || _irt_missing="$_irt_missing $_irt_tool"
    done
    [ -n "$_irt_missing" ] || { say_ok '依赖检查通过'; return 0; }
    say_warn "缺少依赖：$_irt_missing"
    inst_package_manager || {
        say_err '无法自动安装：需要 Debian/Ubuntu 的 apt-get 或 OpenWrt 的 opkg/apk；请手动补齐上述依赖'
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

inst_validate_basic() {
    _iv_missing=
    [ -n "$MP_SUBSCRIBE_URL" ] || _iv_missing="$_iv_missing --subscribe-url"
    [ -n "$MP_AGH_USER_NAME" ] || _iv_missing="$_iv_missing --agh-user"
    [ -n "$MP_AGH_PASSWORD" ] || _iv_missing="$_iv_missing --agh-password"
    [ -z "$_iv_missing" ] || { say_err "缺少必填参数：$_iv_missing"; return 1; }
    case "$MP_SUBSCRIBE_URL" in http://?*|https://?*) ;; *) say_err '订阅 URL 必须为 http/https 地址'; return 1 ;; esac
    case "$MP_AGH_PASSWORD" in '$2a$'?*|'$2b$'?*|'$2y$'?*) ;; *) say_err 'AGH 密码必须为 bcrypt 哈希'; return 1 ;; esac
    case "$MP_PROXY" in ''|http://?*|https://?*|socks5://?*|socks5h://?*) ;; *) say_err '不支持的外部代理 URL'; return 1 ;; esac
    # 服务文件和 cron 包含安装路径，拒绝无法安全代入这些模板的字符。
    [ -n "$DIR_INST" ] || { say_err '安装目录不能为空'; return 1; }
    case "$DIR_INST" in /*) ;; *) DIR_INST="$PWD/$DIR_INST" ;; esac
    case "$DIR_INST" in *[!a-zA-Z0-9_./-]*) say_err '安装目录只支持字母、数字、下划线、点、斜杠和连字符'; return 1 ;; esac
    MP_REPO_BRANCH=${MP_REPO_BRANCH:-main}
}

inst_validate() {
    inst_validate_basic || return 1
    # Git 分支名的基本约束；拒绝 URL、控制字符和路径穿越，不依赖 git 命令。
    printf '%s' "$MP_REPO_BRANCH" | jq -seR '
        length > 0 and . != "@" and
        (test("[\u0000-\u0020\u007f~^:?*\\[\\\\]") | not) and
        (contains("..") or contains("@{") or startswith("-") or endswith(".") | not) and
        (split("/") | all(.[]; length > 0 and (startswith(".") or endswith(".lock") | not)))
    ' >/dev/null 2>&1 || { say_err '无效分支名；请填写分支名字，不是 URL'; return 1; }
    inst_validate_source
}

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

inst_cleanup() {
    [ -z "${_inst_tmp:-}" ] || rm -rf "$_inst_tmp"
    return 0
}

# 自举无法依赖尚未下载的 common.sh；仅读取当前正式配置的顶层代理端口。
# 与 mp_core_proxy_url 保持 mixed-port → port → socks-port 的优先级。
bootstrap_core_proxy() {
    [ -f "$DIR_INST/core/config.yaml" ] || return 1
    for _bcp_key in mixed-port port socks-port; do
        _bcp_port=$(awk -v key="$_bcp_key" '
            index($0, key ":") == 1 {
                v = substr($0, length(key) + 2)
                sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v)
                sub(/[[:space:]]+#.*/, "", v)
                if ((substr(v,1,1)=="\"" && substr(v,length(v),1)=="\"") ||
                    (substr(v,1,1)=="\047" && substr(v,length(v),1)=="\047")) v=substr(v,2,length(v)-2)
                print v; exit
            }' "$DIR_INST/core/config.yaml")
        case "$_bcp_port" in ''|*[!0-9]*) continue ;; esac
        [ "$_bcp_port" -ge 1 ] 2>/dev/null && [ "$_bcp_port" -le 65535 ] || continue
        case "$_bcp_key" in port) printf 'http://127.0.0.1:%s\n' "$_bcp_port" ;;
            *) printf 'socks5h://127.0.0.1:%s\n' "$_bcp_port" ;; esac
        return 0
    done
    return 1
}

bootstrap_attempt() {
    say_step "下载通道：$2"
    if [ -n "$1" ]; then
        curl --disable --silent --fail -L --connect-timeout 10 --max-time 300 \
            --proxy "$1" --noproxy '' "$_bd_url" -o "$_bd_tmp"
    else
        curl --disable --silent --fail -L --connect-timeout 10 --max-time 300 \
            --proxy '' --noproxy '*' "$_bd_url" -o "$_bd_tmp"
    fi
    _ba_rc=$?
    [ "$_ba_rc" -eq 0 ] && [ -s "$_bd_tmp" ] && return 0
    say_warn "$2 下载失败（curl 退出码 $_ba_rc）"
    return 1
}

# 第三个参数为 0 时只尝试一轮，供分支列表在任一页失败时整体重试。
bootstrap_download() {
    _bd_url=$1; _bd_dst=$2; _bd_retry_allowed=${3:-1}
    _bd_tmp=$(mktemp "$_bd_dst.tmp.XXXXXX") || return 1
    while :; do
        _bd_core=$(bootstrap_core_proxy 2>/dev/null || :)
        _bd_ok=0
        if [ -n "$_bd_core" ] && bootstrap_attempt "$_bd_core" 'Core 本机代理'; then
            _bd_ok=1
        elif [ -n "$MP_PROXY" ] && [ "$MP_PROXY" != "$_bd_core" ] \
            && bootstrap_attempt "$MP_PROXY" '外部后备代理'; then
            _bd_ok=1
        elif bootstrap_attempt '' '直连'; then
            _bd_ok=1
        fi
        if [ "$_bd_ok" -eq 1 ]; then
            mv "$_bd_tmp" "$_bd_dst" && return 0
            rm -f "$_bd_tmp"; return 1
        fi
        if [ "$INSTALL_MODE" != interactive ] || [ "$_bd_retry_allowed" != 1 ]; then
            rm -f "$_bd_tmp"; return 1
        fi
        prompt_to _bd_retry Y '下载失败，重试？(Y/n)'
        case "$_bd_retry" in n|N|no|NO|No) rm -f "$_bd_tmp"; return 1 ;; esac
    done
}

inst_fetch_branches() {
    _ifb_page=1
    : > "$_inst_tmp/branches" || return 1
    while :; do
        bootstrap_download "https://api.github.com/repos/AfxMsgBox/MyRule/branches?per_page=100&page=$_ifb_page" \
            "$_inst_tmp/branches.json" 0 || return 1
        jq -e 'type == "array" and length <= 100 and all(.[];
            (.name | type == "string") and (.name | length > 0) and
            (.name | test("[\u0000-\u001f\u007f]") | not))' \
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
        prompt_to _ib_choice 1 '[2/9] 选择分支编号（回车使用 main）'
        case "$_ib_choice" in ''|*[!0-9]*) say_warn '请输入有效编号'; continue ;; esac
        MP_REPO_BRANCH=$(awk -v n="$_ib_choice" 'NR == n { print; exit }' "$_inst_tmp/branches.sorted")
        [ -n "$MP_REPO_BRANCH" ] && return 0
        say_warn '分支编号超出范围'
    done
}

# 沿用第 2 步收集来源及更新分支；本地安装不访问 GitHub 分支 API。
inst_choose_source() {
    while :; do
        prompt_to _ics_mode 1 '[2/9] 仓库文件来源' '1) GitHub 在线下载' '2) 本地仓库目录'
        case "$_ics_mode" in
            1) _MP_SOURCE_DIR=; inst_choose_branch; return $? ;;
            2)
                prompt_to _MP_SOURCE_DIR "$PWD" '本地仓库根目录（包含 sh、core、agh、domain）'
                inst_validate_source || return 1
                prompt_to MP_REPO_BRANCH main '后续在线更新使用的分支名' \
                    '本次使用本地文件，不查询远端分支；回车为 main'
                return 0 ;;
            *) say_warn '请输入 1 或 2' ;;
        esac
    done
}

inst_bootstrap_file() {
    if [ -n "${_MP_SOURCE_DIR:-}" ]; then
        say_step "读取本地文件：sh/$1"
        _ibf_tmp=$(mktemp "$DIR_SH/.bootstrap.XXXXXX") || return 1
        if ! cp "$_MP_SOURCE_DIR/sh/$1" "$_ibf_tmp" || ! mv "$_ibf_tmp" "$DIR_SH/$1"; then
            rm -f "$_ibf_tmp"; return 1
        fi
    else
        bootstrap_download "$MP_REPO_RAW_URL/sh/$1" "$DIR_SH/$1"
    fi
}

inst_collect_inputs() {
    while :; do
        prompt_to _ic_proxy 1 '[1/9] 外部后备代理（项目资源下载优先尝试 Core）' \
            '1) 不使用外部代理' '2) 输入或沿用已有外部代理'
        case "$_ic_proxy" in
            1) MP_PROXY=; break ;;
            2)
                prompt_to MP_PROXY "${MP_PROXY:-}" '外部代理 URL（http/https/socks5/socks5h）'
                case "$MP_PROXY" in http://?*|https://?*|socks5://?*|socks5h://?*) break ;; esac
                say_warn '请填写有效的代理 URL' ;;
            *) say_warn '请输入 1 或 2' ;;
        esac
    done
    inst_choose_source || return 1
    while :; do
        prompt_to MP_SUBSCRIBE_URL "${MP_SUBSCRIBE_URL:-}" '[3/9] 节点订阅 URL'
        case "$MP_SUBSCRIBE_URL" in http://?*|https://?*) break ;; esac
        say_warn '订阅 URL 必须为非空 http/https 地址'
    done
    while :; do
        prompt_to MP_AGH_USER_NAME "${MP_AGH_USER_NAME:-}" '[4/9] AGH 管理员用户名'
        [ -n "$MP_AGH_USER_NAME" ] && break
        say_warn '用户名不能为空'
    done
    while :; do
        prompt_to MP_AGH_PASSWORD "${MP_AGH_PASSWORD:-}" '[5/9] AGH 管理员密码（bcrypt 哈希）'
        case "$MP_AGH_PASSWORD" in '$2a$'?*|'$2b$'?*|'$2y$'?*) break ;; esac
        say_warn '请提供 $2a$ / $2b$ / $2y$ 开头的 bcrypt 哈希'
    done
    prompt_to MP_LOCAL_DNS "$MP_LOCAL_DNS" '[6/9] AGH 上游 DNS' \
        '回车保留；输入 - 清空，读取 /etc/resolv.conf'
    [ "$MP_LOCAL_DNS" != - ] || MP_LOCAL_DNS=''
    return 0
}

# === 主流程：此前只有函数定义，便于单元测试在无系统副作用下加载 ===
inst_colors
inst_parse_args "$@" || exit 1
if [ "$_inst_help" -eq 1 ]; then inst_usage; exit 0; fi
inst_is_root || { say_err '需要 root 权限运行'; exit 1; }
if [ "$INSTALL_MODE" = interactive ]; then
    # 检查终端必须先于依赖安装，避免无终端调用改变系统。
    ( : <>/dev/tty ) 2>/dev/null || { say_err '无参数安装需要交互终端；自动安装请显式提供命名参数'; exit 1; }
    exec 3<>/dev/tty
    inst_colors
else
    inst_validate_basic || exit 1
fi
inst_detect_os || exit 1
say_section '检查并补齐系统依赖'
inst_require_tools || exit 1

_MP_NONINTERACTIVE=1; _MP_INSTALL_OUTPUT=1
export _MP_NONINTERACTIVE _MP_INSTALL_OUTPUT
trap inst_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [ "$INSTALL_MODE" = interactive ]; then
    _MP_NONINTERACTIVE=0
    DIR_INST=/etc/proxy
    inst_env_override=$(export -p 2>/dev/null | grep -E ' MP_[A-Za-z0-9_]+=' || true)
    [ ! -f "$DIR_INST/sh/env.local.conf" ] || . "$DIR_INST/sh/env.local.conf"
    [ -z "$inst_env_override" ] || eval "$inst_env_override"
    unset inst_env_override
    DIR_INST=/etc/proxy
    MP_LOCAL_DNS="${MP_LOCAL_DNS-223.5.5.5 119.29.29.29}"
    _inst_tmp=$(mktemp -d) || exit 1
    inst_collect_inputs || exit 1
fi
inst_validate || exit 1
export _MP_SOURCE_DIR
DIR_SH="$DIR_INST/sh"; DIR_CORE="$DIR_INST/core"; DIR_AGH="$DIR_INST/agh"
MP_INST_DIR=$DIR_INST
# 只导出本次已确认值，防止子脚本重新加载旧配置时覆盖命令行参数。
export MP_INST_DIR MP_REPO_BRANCH MP_LOCAL_DNS MP_PROXY MP_SUBSCRIBE_URL MP_AGH_USER_NAME MP_AGH_PASSWORD
MP_REPO_BRANCH_PATH=$(printf '%s' "$MP_REPO_BRANCH" | jq -sRr 'split("/") | map(@uri) | join("/")') || exit 1
MP_REPO_RAW_URL="https://raw.githubusercontent.com/AfxMsgBox/MyRule/refs/heads/$MP_REPO_BRANCH_PATH"

say_section '安装概览'
printf '  模式：%s\n  系统：%s\n  目录：%s\n  分支：%s\n' "$INSTALL_MODE" "$os_type" "$DIR_INST" "$MP_REPO_BRANCH"
if [ -n "$_MP_SOURCE_DIR" ]; then
    say_dim "仓库来源：$_MP_SOURCE_DIR（分支设置用于后续在线更新）"
else
    say_dim '仓库来源：GitHub'
fi
say_dim '项目资源下载顺序：Core 本机代理 → 外部后备代理（如有）→ 直连'
reinstall=0
if [ -e "$DIR_CORE/config.yaml" ] || [ -e "$DIR_AGH/agh.yaml" ] || [ -e "$DIR_AGH/dns.conf" ]; then reinstall=1; fi
mkdir -p "$DIR_SH/etc" "$DIR_CORE" "$DIR_AGH" || exit 1

# === 开启 IPv4 转发（透明代理网关需要）===
# systemd 使用 sysctl.d，OpenWrt 使用 /etc/sysctl.conf；LXC 权限不足时只警告。
say_section "启用 IPv4 转发"
case "$os_type" in
    systemd) sysctl_conf=/etc/sysctl.d/99-zz-myproxy.conf ;;
    openwrt) sysctl_conf=/etc/sysctl.conf ;;
esac
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


# === 写 env.local.conf ===
# upsert_conf <key> <value> <file>：已存在则替换，否则追加。
# 值用单引号包裹防止 $ 被 source 时再次展开（bcrypt 哈希含 $）；
# 值里出现的单引号转义为 '\''
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
inst_bootstrap_file env.conf || { say_err '获取 env.conf 失败，请检查文件来源'; exit 1; }
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
prompt_to autostart "Y" "[7/9] 现在启用并启动系统服务？(Y/n)" \
    "Y = 安装服务文件并启用服务；重装会切换配置并重启服务" \
    "n = 跳过；服务文件留在 $DIR_SH/etc，可后续按下面命令手动装"

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

# === 定时更新：每隔 N 天更新，默认 3；输入 n 保留已有设置 ===
# 每天检查是否到期，连续日计数由 run-scheduled-update.sh 负责。
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

if [ "$INSTALL_MODE" = interactive ]; then
    say_section "设置定时更新"
    cron_script_enabled=0; cron_config_enabled=0
    prompt_cron_days cron_script_days "[8/9] 每隔几天更新脚本？" && cron_script_enabled=1
    prompt_cron_days cron_config_days "[9/9] 每隔几天更新配置？" && cron_config_enabled=1
    if [ "$cron_script_enabled" = 1 ] || [ "$cron_config_enabled" = 1 ]; then
        inst_require_tools cron || exit 1
    fi
    cron_changed=0
    if [ "$cron_script_enabled" = 1 ]; then
        if install_cron_job "MyProxy:update-scripts" "$cron_script_days" "$DIR_SH/update-scripts.sh" 0; then
            say_ok "脚本：每隔 $cron_script_days 天更新（03:00 检查）"
            cron_changed=1
        else
            say_warn "脚本定时任务写入失败"
        fi
    else
        say_dim "已跳过脚本定时更新"
    fi
    if [ "$cron_config_enabled" = 1 ]; then
        if install_cron_job "MyProxy:update-configs" "$cron_config_days" "$DIR_SH/update-all-configs-restart-services.sh" 5; then
            say_ok "配置：每隔 $cron_config_days 天更新并重启服务（03:05 检查）"
            cron_changed=1
        else
            say_warn "配置文件定时任务写入失败"
        fi
    else
        say_dim "已跳过配置文件定时更新"
    fi
    if [ "$cron_changed" = 1 ] && [ "$os_type" = openwrt ]; then
        if /etc/init.d/cron enable >/dev/null 2>&1 \
           && /etc/init.d/cron restart >/dev/null 2>&1; then
            say_ok "OpenWrt cron 服务已启用并重启"
        else
            say_warn "定时任务已写入，但 OpenWrt cron 服务启用或重启失败"
        fi
    fi
fi

say_section "安装完成"
printf '%s  %s\n' "${C_B}安装目录${C_R}" "$DIR_INST"
printf '%s  %s\n' "${C_B}仓库分支${C_R}" "$MP_REPO_BRANCH"
printf '%s  %s%s%s   用户名 %s\n' "${C_B}AGH Web ${C_R}" "${C_CYN}" "http://<本机IP>:180" "${C_R}" "$MP_AGH_USER_NAME"
case "$os_type" in
    openwrt) printf '%s  %slogread -e MyProxy -f%s\n' "${C_B}日志    ${C_R}" "${C_D}" "${C_R}" ;;
    systemd) printf '%s  %sjournalctl -t MyProxy -f%s\n' "${C_B}日志    ${C_R}" "${C_D}" "${C_R}" ;;
esac
printf '\n%s\n' "${C_B}以后刷新${C_R}"
say_dim "  脚本:   sh $DIR_SH/update-scripts.sh"
say_dim "  配置:   sh $DIR_SH/update-all-configs-restart-services.sh"
say_dim "  二进制: sh $DIR_SH/update-bin.sh"
