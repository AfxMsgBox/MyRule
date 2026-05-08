#!/bin/sh
# 生成 AdGuardHome 的 dns.conf：
#   1. 顶部写时间戳与默认上游
#   2. 拉取若干域名清单
#   3. 把 Clash payload 行 `- '+.example.com'` 转成 AGH 转发规则
#      `[/example.com/]127.0.0.1:${CORE_DNS_PORT}`
# 命中规则的域名会被转发到代理内核内置 DNS，从而拿到 fake-ip。

# 本脚本所在目录
DIR_SCRIPT=$(dirname "$(readlink -f "$0")")
# 自更新用
URL_SCRIPT="${REPO_RAW_URL:-https://raw.githubusercontent.com/AfxMsgBox/MyRule/main}/sh/update-agh-config.sh"

# 加载公共函数与环境变量
# shellcheck disable=SC1091
. "$DIR_SCRIPT/common.sh"

# 远程清单来源
URL_MYUPSTREAM="$REPO_RAW_URL/agh/myupstream.txt"
URL_MYPROXYLIST="$REPO_RAW_URL/domain/myproxylist.txt"
URL_GPT="$REPO_RAW_URL/domain/gpt.txt"
URL_NOTCN="https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/tld-not-cn.txt"
URL_GFWLIST="https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/gfw.txt"

# 兜底默认值
CORE_DNS_PORT="${CORE_DNS_PORT:-253}"
EXCLUDE_TLDS="${EXCLUDE_TLDS:-bj}"
DIR_AGH="${AGH_DIR:-$DIR_SCRIPT/../agh}"
# 下载缓存目录
mkdir -p "$DIR_AGH/download"
# 输出目标文件
agh_dns="$DIR_AGH/dns.conf"

# 把 Clash payload 行写成 AGH 转发规则；$1=源文件 $2=段头注释
append_payload() {
    # 源文件太小（拉取失败）就跳过整段
    [ "$(get_file_size "$1")" -gt 32 ] || return 0
    # 段头注释，便于人工对照
    printf '\n# %s\n' "$2" >> "$agh_dns"
    # 用 sed 把 `- '+.domain'` / `- 'domain'` 转换成 AGH 行；非 payload 行原样丢弃（-n + p 控制）
    sed -En "s|^[ \t]*- '(\+\.)?([^']+)'[ \t]*$|[/\2/]127.0.0.1:$CORE_DNS_PORT|p" "$1" >> "$agh_dns"
}

echo_log "生成 $agh_dns"
# 顶部写时间戳，方便排查时间点
echo "# Generated at $(date '+%F %T')" > "$agh_dns"

# 默认上游：优先用本地手写的 local.dns.conf；否则取系统默认网关
if [ -f "$DIR_AGH/local.dns.conf" ]; then
    cat "$DIR_AGH/local.dns.conf" >> "$agh_dns"
else
    ip route | awk '/^default/ {print $3; exit}' >> "$agh_dns"
fi

# 拉取自定义上游（[/domain/]server 格式），整段直接追加
echo_log ">>> 拉取 myupstream"
download_file "$URL_MYUPSTREAM" "$DIR_AGH/download/myupstream.txt" 1 \
    && [ "$(get_file_size "$DIR_AGH/download/myupstream.txt")" -gt 8 ] \
    && { printf '\n# My Up Stream\n' >> "$agh_dns"; cat "$DIR_AGH/download/myupstream.txt" >> "$agh_dns"; }

# 自家代理域名清单
echo_log ">>> 拉取 myproxylist"
download_file "$URL_MYPROXYLIST" "$DIR_AGH/download/myproxylist.txt" 1
append_payload "$DIR_AGH/download/myproxylist.txt" "My Proxy List"

# GPT / Google 等专用清单
echo_log ">>> 拉取 gpt"
download_file "$URL_GPT" "$DIR_AGH/download/gpt.txt" 1
append_payload "$DIR_AGH/download/gpt.txt" "GPT List"

# 非中国域名清单
echo_log ">>> 拉取 not-cn"
download_file "$URL_NOTCN" "$DIR_AGH/download/notcn.txt" 1
append_payload "$DIR_AGH/download/notcn.txt" "Not China Domain"

# GFW 清单
echo_log ">>> 拉取 gfwlist"
download_file "$URL_GFWLIST" "$DIR_AGH/download/gfwlist.txt" 1
append_payload "$DIR_AGH/download/gfwlist.txt" "GFW List"

# 排除会与本地 / 行政区缩写冲突的伪 TLD（默认 bj）
if [ -n "$EXCLUDE_TLDS" ]; then
    pat=$(echo "$EXCLUDE_TLDS" | tr ' ' '|')
    sed -i -E "/^\[\/(${pat})\/\]/d" "$agh_dns"
fi

echo_log "生成完成：$(wc -l < "$agh_dns") 行"
