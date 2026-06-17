#!/bin/sh
# 生成 AGH dns.conf：默认上游 + myupstream 原样段 + 各域名清单转发到 mihomo:$MP_CORE_DNS_PORT
. "$(dirname "$(readlink -f "$0")")/common.sh"

agh_dns="$MP_AGH_DIR/dns.conf"
dl_dir="$MP_AGH_DIR/download"
mkdir -p "$dl_dir"

# 把 Clash payload（含 - 'domain' 或 - '+.domain'）转成 AGH 的 [/domain/]server
payload_to_agh() {
    sed -En "s|^[ \t]*- '(\+\.)?([^']+)'[ \t]*$|[/\2/]127.0.0.1:$MP_CORE_DNS_PORT|p" "$1"
}

# fetch_payload <basename> <url> <section-header>
# 下载 → 追加段头 → 转 payload 写入 dns.conf；失败 echo_log 并返回 1
fetch_payload() {
    _bn=$1; _url=$2; _hdr=$3
    echo_log ">>> 拉取 $_bn"
    if ! download_file "$_url" "$dl_dir/$_bn"; then
        echo_log "$_bn 失败，跳过"; return 1
    fi
    printf '\n# %s\n' "$_hdr" >> "$agh_dns"
    payload_to_agh "$dl_dir/$_bn" >> "$agh_dns"
}

echo_log "生成 $agh_dns"
echo "# Generated at $(date '+%F %T')" > "$agh_dns"

# 默认上游：MP_LOCAL_DNS 空时退化为 /etc/resolv.conf 的 nameserver
if [ -n "$MP_LOCAL_DNS" ]; then
    for ns in $MP_LOCAL_DNS; do echo "$ns" >> "$agh_dns"; done
else
    awk '/^nameserver/ {print $2}' /etc/resolv.conf >> "$agh_dns"
fi

# myupstream.txt 已是 [/domain/]server 格式，整段直接 cat
echo_log ">>> 拉取 myupstream"
if download_file "$MP_URL_AGH_MYUPSTREAM" "$dl_dir/myupstream.txt"; then
    printf '\n# My Up Stream\n' >> "$agh_dns"
    cat "$dl_dir/myupstream.txt" >> "$agh_dns"
else
    echo_log "myupstream 失败，跳过"
fi

fetch_payload myproxylist.txt "$MP_URL_DOMAIN_MYPROXYLIST" "My Proxy List"
fetch_payload gpt.txt         "$MP_URL_DOMAIN_GPT"         "GPT List"

# not-cn 列表把 .bj 误算非中国 TLD：用 MP_EXCLUDE_TLDS 过滤
if fetch_payload notcn.txt "$MP_URL_NOTCN" "Not China Domain" && [ -n "$MP_EXCLUDE_TLDS" ]; then
    pat=$(echo "$MP_EXCLUDE_TLDS" | tr ' ' '|')
    sed -i -E "/^\[\/(${pat})\/\]/d" "$agh_dns"
fi

fetch_payload gfwlist.txt "$MP_URL_GFWLIST" "GFW List"

echo_log "生成完成：$(wc -l < "$agh_dns") 行"
