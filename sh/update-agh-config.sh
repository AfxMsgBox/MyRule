#!/bin/sh
# 生成 AdGuardHome 的 dns.conf：
#   1. 顶部写时间戳与默认上游
#   2. 拉取若干域名清单
#   3. 把 Clash payload 行 `- '+.example.com'` 转成 AGH 转发规则
#      `[/example.com/]127.0.0.1:${MP_CORE_DNS_PORT}`

# 自更新用：本脚本的 raw URL（来自 env 全局）
url_self="$MP_URL_UPDATE_AGH_CONFIG_SH"
# 本脚本所在目录
dir_self=$(dirname "$(readlink -f "$0")")
# 加载公共函数与 env
# shellcheck disable=SC1091
. "$dir_self/common.sh"

# 下载缓存目录
mkdir -p "$MP_AGH_DIR/download"
# 输出目标文件
agh_dns="$MP_AGH_DIR/dns.conf"

# 把 Clash payload 行写成 AGH 转发规则；$1=源文件 $2=段头注释
append_payload() {
    # 源文件太小（拉取失败）就跳过整段
    [ "$(get_file_size "$1")" -gt 32 ] || return 0
    # 段头注释，便于人工对照
    printf '\n# %s\n' "$2" >> "$agh_dns"
    # 用 sed 把 `- '+.domain'` / `- 'domain'` 转换成 AGH 行；非 payload 行原样丢弃
    sed -En "s|^[ \t]*- '(\+\.)?([^']+)'[ \t]*$|[/\2/]127.0.0.1:$MP_CORE_DNS_PORT|p" "$1" >> "$agh_dns"
}

echo_log "生成 $agh_dns"
# 顶部写时间戳，方便排查时间点
echo "# Generated at $(date '+%F %T')" > "$agh_dns"

# 默认上游：优先用本地手写的 local.dns.conf；否则取系统默认网关
if [ -f "$MP_AGH_DIR/local.dns.conf" ]; then
    cat "$MP_AGH_DIR/local.dns.conf" >> "$agh_dns"
else
    ip route | awk '/^default/ {print $3; exit}' >> "$agh_dns"
fi

# 拉取自定义上游（[/domain/]server 格式），整段直接追加
echo_log ">>> 拉取 myupstream"
download_file "$MP_URL_AGH_MYUPSTREAM" "$MP_AGH_DIR/download/myupstream.txt" 1 \
    && [ "$(get_file_size "$MP_AGH_DIR/download/myupstream.txt")" -gt 8 ] \
    && { printf '\n# My Up Stream\n' >> "$agh_dns"; cat "$MP_AGH_DIR/download/myupstream.txt" >> "$agh_dns"; }

# 自家代理域名清单
echo_log ">>> 拉取 myproxylist"
download_file "$MP_URL_DOMAIN_MYPROXYLIST" "$MP_AGH_DIR/download/myproxylist.txt" 1
append_payload "$MP_AGH_DIR/download/myproxylist.txt" "My Proxy List"

# GPT / Google 等专用清单
echo_log ">>> 拉取 gpt"
download_file "$MP_URL_DOMAIN_GPT" "$MP_AGH_DIR/download/gpt.txt" 1
append_payload "$MP_AGH_DIR/download/gpt.txt" "GPT List"

# 非中国域名清单
echo_log ">>> 拉取 not-cn"
download_file "$MP_URL_NOTCN" "$MP_AGH_DIR/download/notcn.txt" 1
append_payload "$MP_AGH_DIR/download/notcn.txt" "Not China Domain"

# GFW 清单
echo_log ">>> 拉取 gfwlist"
download_file "$MP_URL_GFWLIST" "$MP_AGH_DIR/download/gfwlist.txt" 1
append_payload "$MP_AGH_DIR/download/gfwlist.txt" "GFW List"

# 排除会与本地 / 行政区缩写冲突的伪 TLD（默认 bj）
if [ -n "$MP_EXCLUDE_TLDS" ]; then
    pat=$(echo "$MP_EXCLUDE_TLDS" | tr ' ' '|')
    sed -i -E "/^\[\/(${pat})\/\]/d" "$agh_dns"
fi

echo_log "生成完成：$(wc -l < "$agh_dns") 行"
