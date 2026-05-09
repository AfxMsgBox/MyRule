#!/bin/sh
url_self="$MP_URL_UPDATE_AGH_CONFIG_SH"
. "$(dirname "$(readlink -f "$0")")/common.sh"

agh_dns="$MP_AGH_DIR/dns.conf"
mkdir -p "$MP_AGH_DIR/download"

# 把 Clash payload 行写成 AGH 转发规则；$1=源文件 $2=段头注释
append_payload() {
    printf '\n# %s\n' "$2" >> "$agh_dns"
    sed -En "s|^[ \t]*- '(\+\.)?([^']+)'[ \t]*$|[/\2/]127.0.0.1:$MP_CORE_DNS_PORT|p" "$1" >> "$agh_dns"
}

echo_log "生成 $agh_dns"
echo "# Generated at $(date '+%F %T')" > "$agh_dns"

# 默认上游：MP_LOCAL_DNS（env.conf 配置，空格分隔）；为空时从 /etc/resolv.conf 取 nameserver
if [ -n "$MP_LOCAL_DNS" ]; then
    for ns in $MP_LOCAL_DNS; do
        echo "$ns" >> "$agh_dns"
    done
else
    awk '/^nameserver/ {print $2}' /etc/resolv.conf >> "$agh_dns"
fi

# 自定义上游（[/domain/]server 格式）：整段直接 cat
echo_log ">>> 拉取 myupstream"
if download_file "$MP_URL_AGH_MYUPSTREAM" "$MP_AGH_DIR/download/myupstream.txt"; then
    printf '\n# My Up Stream\n' >> "$agh_dns"
    cat "$MP_AGH_DIR/download/myupstream.txt" >> "$agh_dns"
else
    echo_log "myupstream 失败，跳过"
fi

# 自家代理域名清单
echo_log ">>> 拉取 myproxylist"
if download_file "$MP_URL_DOMAIN_MYPROXYLIST" "$MP_AGH_DIR/download/myproxylist.txt"; then
    append_payload "$MP_AGH_DIR/download/myproxylist.txt" "My Proxy List"
else
    echo_log "myproxylist 失败，跳过"
fi

# GPT / Google
echo_log ">>> 拉取 gpt"
if download_file "$MP_URL_DOMAIN_GPT" "$MP_AGH_DIR/download/gpt.txt"; then
    append_payload "$MP_AGH_DIR/download/gpt.txt" "GPT List"
else
    echo_log "gpt 失败，跳过"
fi

# 非中国域名：tld-not-cn 把 .bj 误算非中国 TLD，删掉避免本地 .bj 被劫持
echo_log ">>> 拉取 not-cn"
if download_file "$MP_URL_NOTCN" "$MP_AGH_DIR/download/notcn.txt"; then
    append_payload "$MP_AGH_DIR/download/notcn.txt" "Not China Domain"
    if [ -n "$MP_EXCLUDE_TLDS" ]; then
        pat=$(echo "$MP_EXCLUDE_TLDS" | tr ' ' '|')
        sed -i -E "/^\[\/(${pat})\/\]/d" "$agh_dns"
    fi
else
    echo_log "not-cn 失败，跳过"
fi

# GFW 清单
echo_log ">>> 拉取 gfwlist"
if download_file "$MP_URL_GFWLIST" "$MP_AGH_DIR/download/gfwlist.txt"; then
    append_payload "$MP_AGH_DIR/download/gfwlist.txt" "GFW List"
else
    echo_log "gfwlist 失败，跳过"
fi

echo_log "生成完成：$(wc -l < "$agh_dns") 行"
