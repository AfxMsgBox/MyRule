#!/bin/sh
# 生成 AdGuardHome 的 dns.conf：
# 1. 顶部写时间戳与默认上游
# 2. 依次拉取若干域名清单
# 3. 把 Clash payload 行 `- '+.example.com'` 转成 AGH 转发规则 `[/example.com/]127.0.0.1:<CORE_DNS_PORT>`
# 命中这些规则的域名解析会被转发到代理内核内置 DNS，从而拿到 fake-ip。

URL_SCRIPT="${REPO_RAW_URL:-https://raw.githubusercontent.com/AfxMsgBox/MyRule/main}/sh/update-agh-config.sh"
DIR_SCRIPT=$(dirname "$(readlink -f "$0")")

# shellcheck disable=SC1091
. "$DIR_SCRIPT/common.sh"

# 远程域名清单来源
URL_MYUPSTREAM="$REPO_RAW_URL/agh/myupstream.txt"
URL_MYPROXYLIST="$REPO_RAW_URL/domain/myproxylist.txt"
URL_GPT="$REPO_RAW_URL/domain/gpt.txt"
URL_NOTCN="https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/tld-not-cn.txt"
URL_GFWLIST="https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/gfw.txt"

CORE_DNS_PORT="${CORE_DNS_PORT:-253}"
EXCLUDE_TLDS="${EXCLUDE_TLDS:-bj}"
DIR_AGH="${AGH_DIR:-$DIR_SCRIPT/../agh}"
agh_dns="$DIR_AGH/dns.conf"
mkdir -p "$DIR_AGH/download"

# 把 Clash payload 行写成 AGH 转发规则。$1=源文件 $2=段头注释
_append_payload() {
    _src="$1"; _hdr="$2"
    if [ "$(get_file_size "$_src")" -gt 32 ]; then
        printf '\n# %s\n' "$_hdr" >> "$agh_dns"
        sed -En "s|^[ \t]*- '(\+\.)?([^']+)'[ \t]*$|[/\2/]127.0.0.1:$CORE_DNS_PORT|p" "$_src" >> "$agh_dns"
    fi
}

echo_log "生成 $agh_dns"
echo "# Generated at $(date '+%F %T')" > "$agh_dns"

# 默认上游：优先用本地手写的 local.dns.conf；否则取系统默认网关
if [ -f "$DIR_AGH/local.dns.conf" ]; then
    cat "$DIR_AGH/local.dns.conf" >> "$agh_dns"
else
    ip route | awk '/^default/ {print $3}' >> "$agh_dns"
fi

_run_step "拉取 myupstream"  download_file "$URL_MYUPSTREAM"  "$DIR_AGH/download/myupstream.txt"  1
if [ "$(get_file_size "$DIR_AGH/download/myupstream.txt")" -gt 8 ]; then
    printf '\n# My Up Stream\n' >> "$agh_dns"
    cat "$DIR_AGH/download/myupstream.txt" >> "$agh_dns"
fi

_run_step "拉取 myproxylist" download_file "$URL_MYPROXYLIST" "$DIR_AGH/download/myproxylist.txt" 1
_append_payload "$DIR_AGH/download/myproxylist.txt" "My Proxy List"

_run_step "拉取 gpt"         download_file "$URL_GPT"         "$DIR_AGH/download/gpt.txt"         1
_append_payload "$DIR_AGH/download/gpt.txt" "GPT List"

_run_step "拉取 not-cn"      download_file "$URL_NOTCN"       "$DIR_AGH/download/notcn.txt"       1
_append_payload "$DIR_AGH/download/notcn.txt" "Not China Domain"

_run_step "拉取 gfwlist"     download_file "$URL_GFWLIST"     "$DIR_AGH/download/gfwlist.txt"     1
_append_payload "$DIR_AGH/download/gfwlist.txt" "GFW List"

# 排除会与本地 / 行政区缩写冲突的伪 TLD；EXCLUDE_TLDS 用空格或 | 分隔
if [ -n "$EXCLUDE_TLDS" ]; then
    _pat=$(echo "$EXCLUDE_TLDS" | tr ' ' '|')
    sed -i -E "/^\[\/(${_pat})\/\]/d" "$agh_dns"
fi

echo_log "生成完成：$(wc -l < "$agh_dns") 行"
exit 0
