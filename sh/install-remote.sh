#!/bin/sh
# 只把固定命令、受限临时路径和哈希放进 SSH 命令；凭据通过私有文件上传。
inst_ssh() {
    _iss_tty=$1; shift
    set -- "$_iss_tty" -S "$_inst_tmp/ssh" -o ControlMaster=auto -o ControlPersist=600 \
        -o ConnectTimeout=15 -p "$INST_SSH_PORT" "$@"
    [ -z "$INST_SSH_KEY" ] || set -- -i "$INST_SSH_KEY" -o IdentitiesOnly=yes "$@"
    case "$INST_SSH_AUTH" in
        password) set -- -o PubkeyAuthentication=no -o PreferredAuthentications=keyboard-interactive,password "$@" ;;
        key) set -- -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no "$@" ;;
    esac
    ssh "$@"
}

inst_probe_target() {
    say_section '连接并检查目标机'
    # ControlMaster 需要 OpenSSH；OpenWrt 的 Dropbear 客户端不具备此接口。
    case "$(ssh -V 2>&1)" in *OpenSSH*) ;; *) say_err '发起端需要 OpenSSH 客户端（OpenWrt: openssh-client）'; return 1 ;; esac
    inst_ssh -T "$INST_TARGET" 'uname -s; uname -m; id -u; if [ -f /etc/openwrt_release ]; then echo openwrt; elif command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ]; then echo systemd; else echo unsupported; fi' \
        > "$_inst_tmp/probe" || return 1
    [ "$(wc -l < "$_inst_tmp/probe")" -eq 4 ] || { say_err 'SSH 启动输出异常'; return 1; }
    [ "$(sed -n 1p "$_inst_tmp/probe")" = Linux ] || { say_err '目标安装目前需要 Linux / OpenWrt'; return 1; }
    INST_TARGET_ARCH=$(sed -n 2p "$_inst_tmp/probe")
    INST_TARGET_UID=$(sed -n 3p "$_inst_tmp/probe")
    INST_TARGET_OS=$(sed -n 4p "$_inst_tmp/probe")
    case "$INST_TARGET_ARCH" in ''|*[!a-zA-Z0-9_-]*) return 1 ;; esac
    case "$INST_TARGET_UID" in ''|*[!0-9]*) return 1 ;; esac
    case "$INST_TARGET_OS" in openwrt|systemd) ;; *) say_err '目标机需要 OpenWrt 或 systemd'; return 1 ;; esac
    if [ "$INST_TARGET_UID" != 0 ]; then
        inst_ssh -T "$INST_TARGET" 'command -v sudo >/dev/null' \
            || { say_err '非 root SSH 用户需要 sudo'; return 1; }
    fi
    say_ok "目标：$INST_TARGET_OS / $INST_TARGET_ARCH"
}

inst_deploy_remote() {
    say_section '上传安装包'
    tar -czf "$_inst_tmp/bundle.tgz" -C "$1" . || return 1
    _idr_hash=$(mp_sha256 < "$_inst_tmp/bundle.tgz") || return 1
    _idr_tmp=$(inst_ssh -T "$INST_TARGET" 'umask 077; mktemp -d /tmp/myrule.XXXXXXXX') || return 1
    case "$_idr_tmp" in /tmp/myrule.*) ;; *) return 1 ;; esac
    case "${_idr_tmp#/tmp/myrule.}" in ''|*[!a-zA-Z0-9]*) return 1 ;; esac
    _inst_remote_tmp=$_idr_tmp
    # 依赖自举独立于 tar/jq；目标机只从系统软件源补装缺失工具。
    cat "$INST_LIB/install-lib.sh" "$INST_LIB/portable.sh" > "$_inst_tmp/preflight.sh" || return 1
    cat >> "$_inst_tmp/preflight.sh" <<'PREFLIGHT'
inst_colors
inst_is_root && inst_detect_os && inst_require_tools || exit 1
cd "$1" || exit 1
trap 'cd /; rm -rf -- "$1"' EXIT
[ "$(mp_sha256 < bundle.tgz)" = "$2" ] || { say_err '上传校验失败'; exit 1; }
mkdir bundle && tar -xzf bundle.tgz -C bundle || exit 1
sh bundle/repo/sh/install-lib.sh --installer-run --apply "$1/bundle"
PREFLIGHT
    inst_ssh -T "$INST_TARGET" "umask 077; cat > '$_inst_remote_tmp/preflight.sh'" < "$_inst_tmp/preflight.sh" &&
        inst_ssh -T "$INST_TARGET" "umask 077; cat > '$_inst_remote_tmp/bundle.tgz'" < "$_inst_tmp/bundle.tgz" || return 1
    say_section '在目标机安装'
    _idr_sudo=; [ "$INST_TARGET_UID" = 0 ] || _idr_sudo=sudo
    inst_ssh -tt "$INST_TARGET" "$_idr_sudo sh '$_inst_remote_tmp/preflight.sh' '$_inst_remote_tmp' '$_idr_hash'"
}

inst_cleanup() {
    if [ -n "${_inst_remote_tmp:-}" ]; then
        inst_ssh -T "$INST_TARGET" "rm -rf -- '$_inst_remote_tmp'" </dev/null >/dev/null 2>&1 || :
    fi
    if [ -n "${INST_TARGET:-}" ] && [ -S "${_inst_tmp:-}/ssh" ]; then
        ssh -S "$_inst_tmp/ssh" -O exit "$INST_TARGET" >/dev/null 2>&1 || :
    fi
    [ -z "${_inst_tmp:-}" ] || rm -rf -- "$_inst_tmp"
}
