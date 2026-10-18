#!/bin/sh
# Linux / macOS / BusyBox 共用的小工具；无系统改动。

mp_realpath() (
    _rp=$1; _rp_count=0
    while :; do
        _rp_dir=$(CDPATH= cd -P -- "$(dirname "$_rp")" 2>/dev/null && pwd -P) || exit 1
        _rp="$_rp_dir/$(basename "$_rp")"
        [ -L "$_rp" ] || { printf '%s\n' "$_rp"; exit 0; }
        _rp_count=$((_rp_count + 1)); [ "$_rp_count" -le 40 ] || exit 1
        _rp_link=$(readlink "$_rp") || exit 1
        case "$_rp_link" in /*) _rp=$_rp_link ;; *) _rp="$_rp_dir/$_rp_link" ;; esac
    done
)

# 从标准输入计算 SHA-256。macOS 自带 shasum，Linux/BusyBox 使用 sha256sum。
mp_sha256() (
    if command -v sha256sum >/dev/null 2>&1; then _hash=$(sha256sum) || exit 1
    elif command -v shasum >/dev/null 2>&1; then _hash=$(shasum -a 256) || exit 1
    else exit 1
    fi
    _hash=${_hash%% *}
    case "$_hash" in ''|*[!0-9a-f]*) exit 1 ;; esac
    [ "${#_hash}" -eq 64 ] || exit 1
    printf '%s\n' "$_hash"
)

mp_cache_read() {
    _mcr_key=$(printf '%s' "$1" | mp_sha256) || return 1
    _mcr_cache="$_MP_RESOURCE_DIR/$_mcr_key"
    [ -f "$_mcr_cache" ] && [ ! -L "$_mcr_cache" ] && [ -f "$_mcr_cache.sha256" ] \
        || { echo_log '安装包缺少所需资源，停止安装'; return 1; }
    _mcr_hash=$(mp_sha256 < "$_mcr_cache") || return 1
    [ "$_mcr_hash" = "$(cat "$_mcr_cache.sha256")" ] && [ -n "$_mcr_hash" ] \
        && [ "$(wc -c < "$_mcr_cache")" -gt "${3:-8}" ] \
        || { echo_log '安装包资源校验失败'; return 1; }
    mkdir -p "$(dirname "$2")" || return 1
    _mcr_stage=$(mktemp "$2.cache.XXXXXX") || return 1
    if ! cp "$_mcr_cache" "$_mcr_stage" || ! mv "$_mcr_stage" "$2"; then
        rm -f "$_mcr_stage"; return 1
    fi
}

mp_cache_write() {
    [ -n "${_MP_CACHE_WRITE:-}" ] || return 0
    _mcw_key=$(printf '%s' "$1" | mp_sha256) || return 1
    [ -n "$_mcw_key" ] || return 1
    mkdir -p "$_MP_CACHE_WRITE" || return 1
    cp "$2" "$_MP_CACHE_WRITE/$_mcw_key" &&
        mp_sha256 < "$2" > "$_MP_CACHE_WRITE/$_mcw_key.sha256"
}
