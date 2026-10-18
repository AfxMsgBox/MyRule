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
export INST_ENTRY_ROOT
if [ -f "$_inst_dir/install-lib.sh" ]; then exec sh "$_inst_dir/install-lib.sh" --installer-run "$@"; fi

# 自举之前只读取下载所需选项，其余参数交由统一解析器严格校验。
_inst_branch=main; _inst_proxy=; _inst_download_proxy=; _inst_download_set=0
_inst_source=; _inst_target=; _inst_install_dir=/etc/proxy; _inst_interactive=0; _inst_next=
[ "$#" -ne 0 ] || _inst_interactive=1
for _inst_arg do
    if [ -n "$_inst_next" ]; then
        eval "$_inst_next=\$_inst_arg"; _inst_next=; continue
    fi
    _inst_key=${_inst_arg%%=*}
    case "$_inst_key" in
        --branch) _inst_var=_inst_branch ;; --proxy) _inst_var=_inst_proxy ;;
        --download-proxy) _inst_var=_inst_download_proxy; _inst_download_set=1 ;;
        --source-dir) _inst_var=_inst_source ;; --target) _inst_var=_inst_target ;;
        --install-dir) _inst_var=_inst_install_dir ;;
        --interactive) _inst_interactive=1; continue ;;
        --help) printf '%s\n' 'MyRule：无参数交互；命令行必填 --subscribe-url URL，认证选择 --agh-password BCRYPT 或 --no-auth' \
            '可选 --agh-user USER（默认 admin）' \
            '可选 --target USER@HOST --ssh-port PORT --ssh-key FILE --ssh-auth auto|password|key' \
            '--branch NAME --local --source-dir DIR --install-dir DIR --dns DNS --proxy URL --download-proxy URL' \
            '--scripts-days N --configs-days N --no-start --interactive'; exit 0 ;;
        --local) echo '单文件安装器无法推断本地仓库，请从仓库内运行或指定 --source-dir' >&2; exit 1 ;;
        *) continue ;;
    esac
    case "$_inst_arg" in *=*) _inst_val=${_inst_arg#*=}; eval "$_inst_var=\$_inst_val" ;; *) _inst_next=$_inst_var ;; esac
done
if [ -n "$_inst_source" ]; then
    [ -f "$_inst_source/sh/install-lib.sh" ] || { echo '本地仓库缺少 install-lib.sh' >&2; exit 1; }
    exec sh "$_inst_source/sh/install-lib.sh" --installer-run "$@"
fi
if [ "$_inst_interactive" = 1 ]; then
    ( : <>/dev/tty ) 2>/dev/null || { echo '交互安装需要终端' >&2; exit 1; }
    printf '\nMyRule · 获取安装器模块\n发起端下载代理（空值直连）> ' > /dev/tty
    IFS= read -r _inst_download_proxy < /dev/tty || exit 1
    _inst_download_set=1
fi
[ "$_inst_download_set" = 1 ] || { [ -n "$_inst_target" ] || _inst_download_proxy=$_inst_proxy; }
# 浏览器下载的单文件也能自举。完整依赖检查在模块中进行。
_inst_packages=
for _inst_tool in curl jq tar; do command -v "$_inst_tool" >/dev/null 2>&1 || _inst_packages="$_inst_packages $_inst_tool"; done
if [ ! -s /etc/ssl/cert.pem ] && [ ! -s /etc/ssl/certs/ca-certificates.crt ]; then _inst_packages="$_inst_packages ca-certificates"; fi
if [ -n "$_inst_packages" ]; then
    printf '缺少依赖，准备安装：%s\n' "$_inst_packages"
    _inst_sudo=; [ "$(id -u)" = 0 ] || _inst_sudo=sudo
    if [ "$(uname -s)" = Darwin ] && command -v brew >/dev/null 2>&1; then brew install $_inst_packages || exit 1
    elif command -v apk >/dev/null 2>&1; then $_inst_sudo apk update && $_inst_sudo apk add $_inst_packages || exit 1
    elif command -v opkg >/dev/null 2>&1; then
        _inst_packages=$(printf '%s' "$_inst_packages" | sed 's/ca-certificates/ca-bundle/g')
        $_inst_sudo opkg update && $_inst_sudo opkg install $_inst_packages || exit 1
    elif command -v apt-get >/dev/null 2>&1; then $_inst_sudo apt-get update && $_inst_sudo apt-get install -y $_inst_packages || exit 1
    else echo '请手动安装上述工具；macOS 可使用 Homebrew' >&2; exit 1; fi
fi
_inst_boot=$(mktemp -d /tmp/myrule-bootstrap.XXXXXXXX) || exit 1
chmod 700 "$_inst_boot" || exit 1
trap 'rm -rf -- "$_inst_boot"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
_inst_branch=$(printf '%s' "${_inst_branch:-main}" | jq -sRr '@uri') || exit 1
_inst_url="https://codeload.github.com/AfxMsgBox/MyRule/tar.gz/refs/heads/$_inst_branch"
[ -z "$_inst_target" ] || _inst_install_dir=/etc/proxy
_inst_port=$(awk '$1=="mixed-port:" {gsub(/[\047\042]/,"",$2); print $2; exit}' "$_inst_install_dir/core/config.yaml" 2>/dev/null)
_inst_core=
case "$_inst_port" in ''|*[!0-9]*) ;; *) _inst_core="socks5h://127.0.0.1:$_inst_port" ;; esac
_inst_ok=0
for _inst_channel in "$_inst_core" "$_inst_download_proxy" DIRECT; do
    [ -n "$_inst_channel" ] || continue
    _inst_noproxy=; [ "$_inst_channel" != DIRECT ] || { _inst_channel=; _inst_noproxy='*'; }
    if curl --disable --silent --fail -L --connect-timeout 10 --max-time 300 --proxy "$_inst_channel" --noproxy "$_inst_noproxy" "$_inst_url" -o "$_inst_boot/repo.tgz"; then _inst_ok=1; break; fi
done
[ "$_inst_ok" = 1 ] || { echo '安装器下载失败，请检查分支、网络或下载代理' >&2; exit 1; }
tar -xzf "$_inst_boot/repo.tgz" -C "$_inst_boot" || exit 1
set +f
for _inst_main in "$_inst_boot"/*/sh/install-lib.sh; do
    [ -f "$_inst_main" ] || { echo '所选分支尚不支持此安装器' >&2; exit 1; }
    _INST_BOOT_PROXY=$_inst_download_proxy; export _INST_BOOT_PROXY
    _INST_BOOT_REPO=${_inst_main%/sh/install-lib.sh}
    _INST_BOOT_BRANCH=$_inst_branch
    export _INST_BOOT_REPO _INST_BOOT_BRANCH
    sh "$_inst_main" --installer-run "$@"
    exit $?
done
