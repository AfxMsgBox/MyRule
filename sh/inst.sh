#!/bin/sh
# 精简入口：本地仓库直接加载模块；单独下载的脚本先取得仓库。
set -f
_inst_entry=$0; _inst_links=0
while [ -L "$_inst_entry" ]; do
    _inst_links=$((_inst_links + 1)); [ "$_inst_links" -le 40 ] || exit 1
    _inst_link=$(readlink "$_inst_entry") || exit 1
    case "$_inst_link" in /*) _inst_entry=$_inst_link ;; *) _inst_entry="$(dirname "$_inst_entry")/$_inst_link" ;; esac
done
_inst_dir=$(CDPATH= cd "$(dirname "$_inst_entry")" && pwd -P) || exit 1
INST_ENTRY_ROOT=
[ ! -f "$_inst_dir/../core/config.yaml" ] || INST_ENTRY_ROOT=$(CDPATH= cd "$_inst_dir/.." && pwd -P)
INST_ENTRY_DIR=$_inst_dir
export INST_ENTRY_ROOT INST_ENTRY_DIR
if [ -f "$_inst_dir/install-lib.sh" ]; then exec sh "$_inst_dir/install-lib.sh" --installer-run "$@"; fi

# 自举之前只读取下载所需选项，其余参数交由统一解析器严格校验。
_inst_branch=main; _inst_proxy=; _inst_download_proxy=; _inst_download_set=0
_inst_log_file=${MP_LOG_FILE:-$_inst_dir/myrule.inst.log}; INST_FILL_FILE=
_inst_source=; _inst_target=; _inst_install_dir=/etc/proxy; _inst_interactive=0; _inst_next=
[ "$#" -ne 0 ] || _inst_interactive=1
for _inst_arg do
    if [ -n "$_inst_next" ]; then
        if [ "$_inst_next" = fill_optional ]; then
            _inst_next=
            case "$_inst_arg" in --*) ;; *) INST_FILL_FILE=$_inst_arg; continue ;; esac
        else
            eval "$_inst_next=\$_inst_arg"; _inst_next=; continue
        fi
    fi
    _inst_key=${_inst_arg%%=*}
    case "$_inst_key" in
        --branch) _inst_var=_inst_branch ;; --proxy) _inst_var=_inst_proxy ;;
        --download-proxy) _inst_var=_inst_download_proxy; _inst_download_set=1 ;;
        --source-dir) _inst_var=_inst_source ;; --target) _inst_var=_inst_target ;;
        --install-dir) _inst_var=_inst_install_dir ;;
        --log-file) _inst_var=_inst_log_file ;;
        --fill-from)
            _inst_interactive=1; INST_FILL_FILE=$_inst_dir/myrule.inst.cfg
            case "$_inst_arg" in *=*) _inst_var=INST_FILL_FILE ;; *) _inst_next=fill_optional; continue ;; esac ;;
        --interactive) _inst_interactive=1; continue ;;
        --help) printf '%s\n' 'MyRule：无参数交互；命令行必填 --subscribe-url URL，认证选择 --agh-password BCRYPT 或 --no-auth' \
            '可选 --agh-user USER（默认 admin）' \
            '可选 --target USER@HOST --ssh-port PORT --ssh-key FILE --ssh-auth auto|password|key' \
            '--branch NAME --local --source-dir DIR --install-dir DIR --dns DNS --proxy URL --download-proxy URL' \
            '--scripts-days N --configs-days N --no-start --interactive --fill-from [PATH] --log-file PATH'; exit 0 ;;
        --local) echo '单文件安装器无法推断本地仓库，请从仓库内运行或指定 --source-dir' >&2; exit 1 ;;
        *) continue ;;
    esac
    case "$_inst_arg" in *=*) _inst_val=${_inst_arg#*=}; eval "$_inst_var=\$_inst_val" ;; *) _inst_next=$_inst_var ;; esac
done
if [ -n "$_inst_source" ]; then
    [ -f "$_inst_source/sh/install-lib.sh" ] || { echo '本地仓库缺少 install-lib.sh' >&2; exit 1; }
    exec sh "$_inst_source/sh/install-lib.sh" --installer-run "$@"
fi
# BEGIN shared HTTP transport (also embedded in standalone inst.sh)
# Resolve a writable private file without following a file symlink.
mp_private_path() (
    [ -n "$1" ] && [ ! -L "$1" ] && { [ ! -e "$1" ] || [ -f "$1" ]; } || exit 1
    case "$1" in */*) _pp_parent=${1%/*}; _pp_parent=${_pp_parent:-/} ;; *) _pp_parent=. ;; esac
    _pp_dir=$(CDPATH= cd -- "$_pp_parent" 2>/dev/null && pwd -P) || exit 1
    printf '%s/%s\n' "$_pp_dir" "${1##*/}"
)

mp_init_log() {
    MP_LOG_FILE=$(mp_private_path "$1") \
        || { printf '%s\n' '日志路径无效，请指定现有目录中的普通文件' >&2; return 1; }
    if [ -n "${INST_FILL_FILE:-}" ] && [ "$(mp_private_path "$INST_FILL_FILE")" = "$MP_LOG_FILE" ]; then
        printf '%s\n' '配置文件与日志文件不能使用同一路径' >&2; return 1
    fi
    (umask 077; : >> "$MP_LOG_FILE") \
        || { printf '%s\n' '无法写入下载命令日志' >&2; return 1; }
    if command -v chmod >/dev/null 2>&1; then chmod 600 "$MP_LOG_FILE" || return 1; fi
    export MP_LOG_FILE
}

mp_log_event() (
    [ -n "${MP_LOG_FILE:-}" ] && [ -f "$MP_LOG_FILE" ] && [ ! -L "$MP_LOG_FILE" ] || exit 0
    _le_time=$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || printf unknown)
    printf '[%s] %s\n' "$_le_time" "$*" >> "$MP_LOG_FILE"
)

mp_download_message() { printf '%s\n' "$*" >&2; mp_log_event "$*"; }

# Optional wizard defaults are JSON data, never sourced or evaluated as shell code.
mp_fill_init() {
    [ -n "${INST_FILL_FILE:-}" ] || return 0
    INST_FILL_FILE=$(mp_private_path "$INST_FILL_FILE") \
        || { mp_download_message '交互配置文件路径无效'; return 1; }
    [ "$INST_FILL_FILE" != "${MP_LOG_FILE:-}" ] \
        || { printf '%s\n' '配置文件与日志文件不能使用同一路径' >&2; return 1; }
    if [ ! -e "$INST_FILL_FILE" ]; then
        (umask 077; printf '{}\n' > "$INST_FILL_FILE") || return 1
    fi
    jq -e 'type=="object" and all(.[]; type=="string" and (explode | index(0)==null))' \
        "$INST_FILL_FILE" >/dev/null 2>&1 \
        || { mp_download_message '交互配置必须为 JSON 对象，字段值须为不含空字符的字符串'; return 1; }
    chmod 600 "$INST_FILL_FILE" || return 1
}

mp_fill_default() {
    if [ -n "${INST_FILL_FILE:-}" ]; then
        jq -r --arg key "$1" --arg fallback "$2" 'if has($key) then .[$key] else $fallback end' "$INST_FILL_FILE"
    else printf '%s\n' "$2"; fi
}

mp_fill_save() (
    [ -n "${INST_FILL_FILE:-}" ] || exit 0
    umask 077
    _fs_tmp=$(mktemp "$INST_FILL_FILE.tmp.XXXXXX") || exit 1
    trap 'rm -f -- "$_fs_tmp"' EXIT
    jq --arg key "$1" --arg value "$2" '.[$key]=$value' "$INST_FILL_FILE" > "$_fs_tmp" \
        && chmod 600 "$_fs_tmp" && mv "$_fs_tmp" "$INST_FILL_FILE" \
        || { mp_download_message '保存交互配置失败'; exit 1; }
    mp_log_event "交互配置已更新字段：$1"
)

# Keep public project download paths; private resource paths/queries may contain tokens.
mp_log_url() (
    _lu_url=$1; _lu_scheme=${1%%://*}; _lu_tail=${1#*://}
    _lu_host=${_lu_tail%%[/?#]*}
    case "$_lu_host" in *@*) _lu_host="<redacted>@${_lu_host##*@}" ;; esac
    _lu_base=${_lu_url%%\?*}; _lu_base=${_lu_base%%\#*}
    if [ "${2:-}" = proxy ]; then
        _lu_safe="$_lu_scheme://$_lu_host"
    else
        case "$_lu_base" in
            https://github.com/AfxMsgBox/MyRule/*|https://codeload.github.com/AfxMsgBox/MyRule/*|https://api.github.com/repos/AfxMsgBox/MyRule/*|https://raw.githubusercontent.com/AfxMsgBox/MyRule/*|\
            https://github.com/MetaCubeX/mihomo/*|https://api.github.com/repos/MetaCubeX/mihomo/*|https://github.com/MetaCubeX/metacubexd/*|https://github.com/AdguardTeam/AdGuardHome/*|\
            https://adguardteam.github.io/HostlistsRegistry/assets/*|https://raw.githubusercontent.com/Loyalsoldier/clash-rules/*)
                _lu_safe=$_lu_base ;;
            *) _lu_safe="$_lu_scheme://$_lu_host/<redacted>" ;;
        esac
    fi
    case "$_lu_url" in *\?*) _lu_safe="$_lu_safe?<redacted>" ;; esac
    case "$_lu_url" in *\#*) _lu_safe="$_lu_safe#<redacted>" ;; esac
    printf '%s' "$_lu_safe"
)

# Shell-quote arguments without eval or external tools (also used before dependency setup).
mp_log_command() (
    mp_init_log "${MP_LOG_FILE:-${INST_ENTRY_DIR:-${MP_INST_DIR:-.}/sh}/myrule.inst.log}" || exit 1
    exec >> "$MP_LOG_FILE" || exit 1
    mp_log_event '执行命令（敏感值已脱敏）'
    printf '  [命令，敏感值已脱敏]'
    _lc_kind=
    for _lc_arg do
        _lc_next=
        case "$_lc_arg" in --proxy) _lc_next=proxy ;; esac
        case "$_lc_arg" in
            http://*|https://*|socks5://*|socks5h://*) _lc_arg=$(mp_log_url "$_lc_arg" "$_lc_kind") ;;
            'Authorization:'*) _lc_arg='Authorization: <redacted>' ;;
        esac
        printf " '"
        while :; do
            case "$_lc_arg" in
                *\'*) printf '%s' "${_lc_arg%%\'*}" "'\\''"; _lc_arg=${_lc_arg#*\'} ;;
                *) printf "%s'" "$_lc_arg"; break ;;
            esac
        done
        _lc_kind=$_lc_next
    done
    printf '\n'
)

mp_run_download_command() {
    mp_log_command "$@" || return 1
    _rd_rc=0; "$@" || _rd_rc=$?
    mp_log_event "命令结束：$1，退出码 $_rd_rc"
    return "$_rd_rc"
}

# Render only byte counts and response size, never raw curl output or headers.
mp_download_progress() {
    _dp_line=$(awk -v bytes="$1" -v seconds="$2" -v done="$3" '
        /^HTTP\// { total=0; gsub(/\r/, "", $2); ok=($2 ~ /^2[0-9][0-9]$/) }
        tolower($1)=="content-length:" && ok {
            gsub(/\r/, "", $2); if ($2 ~ /^[0-9]+$/) total=$2+0
        }
        END {
            rate=bytes/(seconds>0 ? seconds : 1)/1048576
            if (total>0) {
                pct=int(bytes*100/total); if(pct>100) pct=100
                bar=""; for(i=0;i<20;i++) bar=bar (i<int(pct/5) ? "#" : "-")
                printf "  [%s] %3d%%  %.2f/%.2f MiB", bar,pct,bytes/1048576,total/1048576
            } else printf "  已下载 %d 字节 (%.2f MiB)",bytes,bytes/1048576
            printf " | 均速 %.2f MiB/s | %ds%s",rate,seconds,(done ? " | 下载完成" : "")
        }
    ' "$4")
    printf '%s' "$_dp_line" >&2
    mp_log_event "$_dp_line"
}

# URL/output/Core/fallback/label/timeout/min-size. Only log sanitized commands.
mp_http_download() (
    _hd_url=$1; _hd_dst=$2; _hd_core=$3; _hd_proxy=$4
    _hd_label=${5:-文件}; _hd_timeout=${6:-300}; _hd_min=${7:-0}
    _hd_meta=$(mktemp -d) || exit 1
    _hd_pid=
    trap '[ -z "$_hd_pid" ] || { kill "$_hd_pid" 2>/dev/null; wait "$_hd_pid" 2>/dev/null; }; rm -rf -- "$_hd_meta"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    mp_init_log "${MP_LOG_FILE:-${INST_ENTRY_DIR:-${MP_INST_DIR:-.}/sh}/myrule.inst.log}" || exit 1
    mp_download_message "下载：$_hd_label"
    _hd_round=0
    while :; do
        _hd_transient=0
        for _hd_kind in core fallback direct; do
            case "$_hd_kind" in
                core) [ -n "$_hd_core" ] || continue; _hd_channel=$_hd_core; _hd_name='Core 本机代理' ;;
                fallback) [ -n "$_hd_proxy" ] && [ "$_hd_proxy" != "$_hd_core" ] || continue
                    _hd_channel=$_hd_proxy; _hd_name='外部后备代理' ;;
                direct) _hd_channel=; _hd_name=直连 ;;
            esac
            mp_download_message "  尝试：$_hd_name"
            _hd_noproxy=; [ -n "$_hd_channel" ] || _hd_noproxy='*'
            set -- --disable --fail -L --connect-timeout 10 --max-time "$_hd_timeout" \
                --speed-limit 1 --speed-time 30 --proxy "$_hd_channel" --noproxy "$_hd_noproxy" \
                --write-out '%{http_code}' --dump-header "$_hd_meta/headers" "$_hd_url" -o "$_hd_dst" --silent
            : > "$_hd_dst" || exit 1
            : > "$_hd_meta/headers"
            _hd_start=$(date +%s); _hd_last=-5; _hd_previous=0
            mp_log_command curl "$@" || exit 1
            curl "$@" > "$_hd_meta/http" 2>/dev/null &
            _hd_pid=$!
            while kill -0 "$_hd_pid" 2>/dev/null; do
                _hd_bytes=$(wc -c < "$_hd_dst"); _hd_elapsed=$(($(date +%s) - _hd_start))
                if { [ -t 2 ] && [ "$_hd_elapsed" -gt "$_hd_last" ]; } || [ "$((_hd_elapsed - _hd_last))" -ge 5 ] \
                    || { [ "$_hd_previous" -eq 0 ] && [ "$_hd_bytes" -gt 0 ]; }; then
                    [ ! -t 2 ] || printf '\r\033[K' >&2
                    mp_download_progress "$_hd_bytes" "$_hd_elapsed" 0 "$_hd_meta/headers"
                    [ -t 2 ] || printf '\n' >&2
                    _hd_last=$_hd_elapsed; _hd_previous=$_hd_bytes
                fi
                sleep 0.2
            done
            _hd_rc=0; wait "$_hd_pid" || _hd_rc=$?; _hd_pid=
            _hd_bytes=$(wc -c < "$_hd_dst"); _hd_elapsed=$(($(date +%s) - _hd_start))
            _hd_http=$(cat "$_hd_meta/http")
            case "$_hd_http" in [0-9][0-9][0-9]) ;; *) _hd_http=000 ;; esac
            if [ "$_hd_rc" = 0 ] && [ "$_hd_bytes" -gt "$_hd_min" ]; then
                mp_log_event "下载成功：$_hd_label；curl 0；HTTP $_hd_http；$_hd_bytes 字节；${_hd_elapsed}s"
                [ ! -t 2 ] || printf '\r\033[K' >&2
                mp_download_progress "$_hd_bytes" "$_hd_elapsed" 1 "$_hd_meta/headers"
                printf '\n' >&2
                exit 0
            fi
            [ ! -t 2 ] || printf '\n' >&2
            _hd_retry=0
            case "$_hd_rc" in
                0) _hd_reason='响应为空或过小' ;;
                5|6) _hd_reason='DNS 解析失败'; _hd_retry=1 ;;
                7) _hd_reason='连接失败'; _hd_retry=1 ;;
                18|52|55|56) _hd_reason='传输中断'; _hd_retry=1 ;;
                28) _hd_reason='请求超时或连续 30 秒无数据'; _hd_retry=1 ;;
                35) _hd_reason='TLS 握手失败'; _hd_retry=1 ;;
                60) _hd_reason='TLS 证书校验失败' ;;
                22) _hd_reason='HTTP 请求失败'
                    case "$_hd_http" in 408|429|500|502|503|504) _hd_retry=1 ;; esac ;;
                23|26) _hd_reason='本地文件读写失败' ;;
                *) _hd_reason='下载失败' ;;
            esac
            mp_download_message "  $_hd_name：$_hd_reason（curl $_hd_rc，HTTP $_hd_http）"
            # Retry only if the final direct attempt was transient; a final 404/403 is conclusive.
            _hd_transient=$_hd_retry
            case "$_hd_rc" in 23|26) exit 1 ;; esac
        done
        [ "$_hd_transient" = 1 ] && [ "$_hd_round" -lt 2 ] || exit 1
        _hd_round=$((_hd_round + 1))
        mp_download_message "  临时错误，自动重试 $_hd_round/2"
        sleep 1
    done
)
# END shared HTTP transport

mp_init_log "$_inst_log_file" || exit 1
printf '安装日志：%s\n' "$MP_LOG_FILE"
mp_log_event "独立安装入口：$INST_ENTRY_DIR；系统：$(uname -srm)"
# 浏览器下载的单文件也能自举。完整依赖检查在模块中进行。
_inst_packages=
for _inst_tool in curl jq tar; do command -v "$_inst_tool" >/dev/null 2>&1 || _inst_packages="$_inst_packages $_inst_tool"; done
if [ ! -s /etc/ssl/cert.pem ] && [ ! -s /etc/ssl/certs/ca-certificates.crt ]; then _inst_packages="$_inst_packages ca-certificates"; fi
if [ -n "$_inst_packages" ]; then
    printf '缺少依赖，准备安装：%s\n' "$_inst_packages"
    _inst_sudo=; [ "$(id -u)" = 0 ] || _inst_sudo=sudo
    if [ "$(uname -s)" = Darwin ] && command -v brew >/dev/null 2>&1; then mp_run_download_command brew install $_inst_packages || exit 1
    elif command -v apk >/dev/null 2>&1; then mp_run_download_command $_inst_sudo apk update && mp_run_download_command $_inst_sudo apk add $_inst_packages || exit 1
    elif command -v opkg >/dev/null 2>&1; then
        _inst_packages=$(printf '%s' "$_inst_packages" | sed 's/ca-certificates/ca-bundle/g')
        mp_run_download_command $_inst_sudo opkg update && mp_run_download_command $_inst_sudo opkg install $_inst_packages || exit 1
    elif command -v apt-get >/dev/null 2>&1; then mp_run_download_command $_inst_sudo apt-get update && mp_run_download_command $_inst_sudo apt-get install -y $_inst_packages || exit 1
    else echo '请手动安装上述工具；macOS 可使用 Homebrew' >&2; exit 1; fi
fi
mp_fill_init || exit 1
if [ "$_inst_interactive" = 1 ]; then
    ( : <>/dev/tty ) 2>/dev/null || { echo '交互安装需要终端' >&2; exit 1; }
    _inst_download_proxy=$(mp_fill_default INST_DOWNLOAD_PROXY "$_inst_download_proxy") || exit 1
    printf '\nMyRule · 获取安装器模块\n发起端下载代理（空值直连）[%s]> ' "$_inst_download_proxy" > /dev/tty
    IFS= read -r _inst_input < /dev/tty || exit 1
    _inst_download_proxy=${_inst_input:-$_inst_download_proxy}
    mp_fill_save INST_DOWNLOAD_PROXY "$_inst_download_proxy" || exit 1
    _inst_download_set=1
    _inst_branch=$(mp_fill_default MP_REPO_BRANCH "$_inst_branch") || exit 1
fi
[ "$_inst_download_set" = 1 ] || { [ -n "$_inst_target" ] || _inst_download_proxy=$_inst_proxy; }
_inst_boot=$(mktemp -d /tmp/myrule-bootstrap.XXXXXXXX) || exit 1
chmod 700 "$_inst_boot" || exit 1
trap '_inst_rc=$?; mp_log_event "独立入口退出码：$_inst_rc"; rm -rf -- "$_inst_boot"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
[ -z "$_inst_target" ] || _inst_install_dir=/etc/proxy
_inst_port=$(awk '$1=="mixed-port:" {gsub(/[\047\042]/,"",$2); print $2; exit}' "$_inst_install_dir/core/config.yaml" 2>/dev/null)
_inst_core=
case "$_inst_port" in ''|*[!0-9]*) ;; *) _inst_core="socks5h://127.0.0.1:$_inst_port" ;; esac

_inst_download() {
    mp_http_download "$1" "$2" "$_inst_core" "$_inst_download_proxy" "${3:-安装器资源}" "${4:-300}"
}
# 选择必须发生在下载模块之前；独立文件无法得知自己来自哪个分支。
if [ "$_inst_interactive" = 1 ]; then
    _inst_page=1
    : > "$_inst_boot/branches"
    while :; do
        _inst_download "https://api.github.com/repos/AfxMsgBox/MyRule/branches?per_page=100&page=$_inst_page" "$_inst_boot/page.json" "GitHub 分支列表（第 $_inst_page 页）" 60 \
            && jq -e 'type == "array" and length <= 100 and all(.[];
                (.name | type == "string") and (.name | length > 0) and
                (.name | explode | all(. >= 32 and . != 127)))' "$_inst_boot/page.json" >/dev/null 2>&1 \
            || { echo '无法获取完整分支列表，请检查网络或 GitHub API 限流后重试' >&2; exit 1; }
        jq -r '.[].name' "$_inst_boot/page.json" >> "$_inst_boot/branches" || exit 1
        [ "$(jq length "$_inst_boot/page.json")" = 100 ] || break
        _inst_page=$((_inst_page + 1))
    done
    grep -qxF main "$_inst_boot/branches" || { echo '分支列表缺少 main' >&2; exit 1; }
    { printf 'main\n'; LC_ALL=C sort -u "$_inst_boot/branches" | sed '/^main$/d'; } > "$_inst_boot/choices"
    _inst_color=; _inst_reset=
    if [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != dumb ]; then
        _inst_color=$(printf '\033[1;36m'); _inst_reset=$(printf '\033[0m')
    fi
    printf '\n%sGitHub 分支%s\n' "$_inst_color" "$_inst_reset" > /dev/tty
    awk '{ printf "  %d) %s\n", NR, $0 }' "$_inst_boot/choices" > /dev/tty
    _inst_default=$(awk -v branch="${_inst_branch:-main}" '$0 == branch { print NR; exit }' "$_inst_boot/choices")
    while :; do
        printf '选择分支编号 [%s]> ' "${_inst_default:-1}" > /dev/tty
        IFS= read -r _inst_choice < /dev/tty || exit 1
        _inst_choice=${_inst_choice:-${_inst_default:-1}}
        case "$_inst_choice" in *[!0-9]*) continue ;; esac
        _inst_branch=$(awk -v n="$_inst_choice" 'NR == n { print; exit }' "$_inst_boot/choices")
        [ -z "$_inst_branch" ] || break
        printf '分支编号超出范围\n' > /dev/tty
    done
    mp_fill_save MP_REPO_BRANCH "$_inst_branch" || exit 1
    _INST_BOOT_SELECTED=$_inst_branch; export _INST_BOOT_SELECTED
fi
_inst_branch=$(printf '%s' "${_inst_branch:-main}" | jq -sRr '@uri') || exit 1
_inst_url="https://codeload.github.com/AfxMsgBox/MyRule/tar.gz/refs/heads/$_inst_branch"
_inst_download "$_inst_url" "$_inst_boot/repo.tgz" "安装器仓库归档" \
    || { echo '安装器下载失败，请检查分支、网络或下载代理' >&2; exit 1; }
tar -xzf "$_inst_boot/repo.tgz" -C "$_inst_boot" || exit 1
set +f
for _inst_main in "$_inst_boot"/*/sh/install-lib.sh; do
    [ -f "$_inst_main" ] || { printf '分支 %s 缺少 sh/install-lib.sh，请选择包含新版安装器的分支\n' "$_inst_branch" >&2; exit 1; }
    _INST_BOOT_PROXY=$_inst_download_proxy; export _INST_BOOT_PROXY
    _INST_BOOT_REPO=${_inst_main%/sh/install-lib.sh}
    _INST_BOOT_BRANCH=$_inst_branch
    export _INST_BOOT_REPO _INST_BOOT_BRANCH
    sh "$_inst_main" --installer-run "$@"
    exit $?
done
