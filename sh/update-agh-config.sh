#!/bin/sh
# 生成 AGH dns.conf：默认上游 + myupstream 原样段 + 各域名清单转发到 Core dns.listen
. "$(dirname "$(readlink -f "$0")")/common.sh"

agh_dns="$MP_AGH_DIR/dns.conf"
dl_dir="$MP_AGH_DIR/download"
core_config="${1:-$MP_CORE_DIR/config.yaml}"
mkdir -p "$MP_AGH_DIR" "$dl_dir"
agh_dns_staged=$(mktemp "$MP_AGH_DIR/dns.conf.tmp.XXXXXX") || exit 1
core_dns=$(mp_core_dns_endpoint "$core_config") \
    || { echo_log "无法从 Core 配置读取有效的 dns.listen"; rm -f "$agh_dns_staged"; exit 1; }

# 把 Clash payload（含 - 'domain' 或 - '+.domain'）转成 AGH 的 [/domain/]server
payload_to_agh() {
    sed -En "s|^[ \t]*- '(\+\.)?([^']+)'[ \t]*$|[/\2/]$core_dns|p" "$1"
}

# fetch_payload <basename> <url> <section-header>
# 下载 → 追加段头 → 转 payload 写入临时 dns.conf；全部成功后才替换正式文件。
fetch_payload() {
    _bn=$1; _url=$2; _hdr=$3
    echo_log ">>> 拉取 $_bn"
    if ! download_file "$_url" "$dl_dir/$_bn"; then
        echo_log "$_bn 失败，跳过"; return 1
    fi
    printf '\n# %s\n' "$_hdr" >> "$agh_dns_staged"
    payload_to_agh "$dl_dir/$_bn" >> "$agh_dns_staged"
}

echo_log "生成 $agh_dns"
echo "# Generated at $(date '+%F %T')" > "$agh_dns_staged"
rc=0

# 默认上游：MP_LOCAL_DNS 空时退化为 /etc/resolv.conf 的 nameserver
if [ -n "$MP_LOCAL_DNS" ]; then
    for ns in $MP_LOCAL_DNS; do echo "$ns" >> "$agh_dns_staged"; done
else
    awk '/^nameserver/ {print $2}' /etc/resolv.conf >> "$agh_dns_staged"
fi

# myupstream.txt 已是 [/domain/]server 格式，整段直接 cat
echo_log ">>> 拉取 myupstream"
if download_file "$MP_REPO_RAW_URL/agh/myupstream.txt" "$dl_dir/myupstream.txt"; then
    printf '\n# My Up Stream\n' >> "$agh_dns_staged"
    cat "$dl_dir/myupstream.txt" >> "$agh_dns_staged"
else
    echo_log "myupstream 失败"
    rc=$((rc+1))
fi

fetch_payload myproxylist.txt "$MP_REPO_RAW_URL/domain/myproxylist.txt" "My Proxy List" \
    || rc=$((rc+1))
fetch_payload gpt.txt "$MP_REPO_RAW_URL/domain/gpt.txt" "GPT List" \
    || rc=$((rc+1))

# not-cn 列表把 .bj 误算非中国 TLD，转换该段时直接剔除。
echo_log ">>> 拉取 notcn.txt"
if download_file \
        "https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/tld-not-cn.txt" \
        "$dl_dir/notcn.txt"; then
    printf '\n# Not China Domain\n' >> "$agh_dns_staged"
    payload_to_agh "$dl_dir/notcn.txt" | sed -E '/^\[\/bj\/\]/d' >> "$agh_dns_staged"
else
    echo_log "notcn.txt 失败"
    rc=$((rc+1))
fi

fetch_payload gfwlist.txt \
    "https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/gfw.txt" \
    "GFW List" || rc=$((rc+1))

if [ "$rc" -ne 0 ]; then
    rm -f "$agh_dns_staged"
    echo_log "AGH dns.conf 更新失败，保留原文件（$rc 项下载失败）"
    exit 1
fi
mv "$agh_dns_staged" "$agh_dns"
echo_log "生成完成：$(wc -l < "$agh_dns") 行"
