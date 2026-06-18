#!/bin/sh
# MyProxy 一键安装：交互式收集敏感参数 → 下载脚本/服务文件/二进制 → 渲染配置 → 可选启动服务。
#
# 用法（需 root；第一位置参数 = 安装根，省略用 $PWD）：
#   mkdir -p /opt/myproxy && cd $_ && sh inst.sh        # 装到 /opt/myproxy/{sh,core,agh}
#   sh inst.sh /etc/proxy                                # 显式指定，装到 /etc/proxy/{sh,core,agh}
# wget|sh 管道（向导从 /dev/tty 读，不吃脚本流）：
#   mkdir -p /opt/myproxy && cd $_
#   wget -O- https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/inst.sh | sh
# 自托管 / 分支调试：
#   MP_REPO_RAW_URL=https://raw.githubusercontent.com/AfxMsgBox/MyRule/refs/heads/<branch> \
#       wget -O- "$MP_REPO_RAW_URL/sh/inst.sh" | sh

[ "$(id -u)" = "0" ] || { echo "需要 root 权限运行（Debian/Ubuntu 请加 sudo）" >&2; exit 1; }

# === 颜色（tty 启用；设 NO_COLOR=1 禁用）===
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_R=$(printf '\033[0m');    C_D=$(printf '\033[2m');    C_B=$(printf '\033[1m')
    C_RED=$(printf '\033[31m'); C_GRN=$(printf '\033[32m'); C_YEL=$(printf '\033[33m')
    C_BLU=$(printf '\033[34m'); C_CYN=$(printf '\033[36m')
else
    C_R= C_D= C_B= C_RED= C_GRN= C_YEL= C_BLU= C_CYN=
fi
say_section() { printf '\n%s\n' "${C_B}${C_CYN}━━━ $* ━━━${C_R}"; }
say_step()    { printf '%s\n'   "${C_B}${C_BLU}>>>${C_R} ${C_B}$*${C_R}"; }
say_ok()      { printf '%s\n'   "${C_GRN}$*${C_R}"; }
say_warn()    { printf '%s\n'   "${C_YEL}$*${C_R}"; }
say_err()     { printf '%s\n'   "${C_RED}$*${C_R}"; }
say_dim()     { printf '%s\n'   "${C_D}$*${C_R}"; }

# === 路径 ===
DIR_INST="${1:-$PWD}"
DIR_SH="$DIR_INST/sh"
DIR_CORE="$DIR_INST/core"
DIR_AGH="$DIR_INST/agh"
mkdir -p "$DIR_SH/etc" "$DIR_CORE" "$DIR_AGH"

# === OS 识别：先就地探测（common.sh 还没加载，无法用 mp_detect_os） ===
if [ -z "$MP_OS_TYPE" ]; then
    if [ -f /etc/openwrt_release ] || grep -qs '^ID=.*openwrt' /etc/os-release; then
        MP_OS_TYPE=openwrt
    elif command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ]; then
        MP_OS_TYPE=systemd
    else
        echo "未识别的系统；用 MP_OS_TYPE=openwrt 或 MP_OS_TYPE=systemd 强制" >&2
        exit 1
    fi
fi
export MP_OS_TYPE

say_section "MyProxy 安装向导"
printf '%s\n' "${C_B}目标系统${C_R}    $MP_OS_TYPE"
printf '%s\n' "${C_B}安装根目录${C_R}  $DIR_INST"
say_dim "  脚本 → $DIR_SH    (含 sh/etc/ 服务文件副本)"
say_dim "  core → $DIR_CORE"
say_dim "  agh  → $DIR_AGH"

# === 预加载已有 env.local.conf（提供重装场景的默认值） ===
[ -f "$DIR_SH/env.local.conf" ] && . "$DIR_SH/env.local.conf"

# === 交互向导：能读 /dev/tty 就开问，否则跳过 ===
HAVE_TTY=0
{ : >/dev/tty; } 2>/dev/null && [ -r /dev/tty ] && HAVE_TTY=1

# prompt_to <var> <default> <label> [hint_lines...]
#   HAVE_TTY=0 时直接把 default 赋给 var；=1 时显示 label / hint / [default] 等输入
prompt_to() {
    _p_var=$1; _p_def=$2; _p_label=$3
    shift 3
    [ "$HAVE_TTY" = "1" ] || { eval "$_p_var=\$_p_def"; return; }
    printf '\n%s%s%s\n' "${C_B}${C_CYN}" "$_p_label" "${C_R}" >/dev/tty
    for _p_hint in "$@"; do printf '  %s%s%s\n' "${C_D}" "$_p_hint" "${C_R}" >/dev/tty; done
    if [ -n "$_p_def" ]; then
        printf '  %s[%s]%s\n  %s>%s ' "${C_D}" "$_p_def" "${C_R}" "${C_GRN}" "${C_R}" >/dev/tty
    else
        printf '  %s[空]%s\n  %s>%s ' "${C_D}" "${C_R}" "${C_GRN}" "${C_R}" >/dev/tty
    fi
    IFS= read -r _p_val </dev/tty || _p_val=""
    [ -n "$_p_val" ] || _p_val="$_p_def"
    eval "$_p_var=\$_p_val"
}

# 分支名 → 完整 raw URL；完整 URL 原样保留
expand_branch() {
    case "$1" in
        http://*|https://*) printf '%s' "$1" ;;
        main|"")            printf 'https://raw.githubusercontent.com/AfxMsgBox/MyRule/main' ;;
        *)                  printf 'https://raw.githubusercontent.com/AfxMsgBox/MyRule/refs/heads/%s' "$1" ;;
    esac
}

if [ "$HAVE_TTY" = "1" ]; then
    # 从已有 URL 反推当前分支（main 默认显示 "main"）
    case "$MP_REPO_RAW_URL" in
        */refs/heads/*) cur_branch="${MP_REPO_RAW_URL##*/refs/heads/}" ;;
        */main|"")      cur_branch="main" ;;
        *)              cur_branch="$MP_REPO_RAW_URL" ;;
    esac

    prompt_to in_branch "$cur_branch" "[1/7] 仓库分支或完整 URL" \
        "主分支:   main" \
        "指定分支: claude/update-readme-overview-pU5D3" \
        "完整 URL: https://raw.githubusercontent.com/owner/repo/refs/heads/dev"
    MP_REPO_RAW_URL=$(expand_branch "$in_branch")

    # 代理选择：1=直连  2=127.0.0.1:7890  3=自定义 HTTP 代理
    # 持久化到 env.local.conf，影响后续 cron 跑 update-* 与 keeplive.sh
    while :; do
        : "${cur_proxy_choice:=1}"
        prompt_to in_proxy "$cur_proxy_choice" "[2/7] 下载是否走 HTTP 代理？" \
            "1) 直连（推荐；首次安装时核心还没起，代理多半不可用）" \
            "2) http://127.0.0.1:7890（本机代理已运行时）" \
            "3) 自定义（接下来输入完整 URL，如 http://192.168.1.1:7890）"
        case "$in_proxy" in
            1) MP_USE_PROXY=0; MP_PROXY_HTTP="http://127.0.0.1:7890"; break ;;
            2) MP_USE_PROXY=1; MP_PROXY_HTTP="http://127.0.0.1:7890"; break ;;
            3) prompt_to MP_PROXY_HTTP "${MP_PROXY_HTTP:-http://127.0.0.1:7890}" "      自定义 HTTP 代理 URL"
               MP_USE_PROXY=1; break ;;
            *) say_err "      请输入 1 / 2 / 3" ;;
        esac
    done
    export MP_USE_PROXY MP_PROXY_HTTP

    prompt_to MP_SUBSCRIBE_URL "$MP_SUBSCRIBE_URL" "[3/7] 节点订阅 URL / MP_SUBSCRIBE_URL"
    prompt_to MP_AGH_USER_NAME "$MP_AGH_USER_NAME" "[4/7] AdGuardHome 管理员用户名 / MP_AGH_USER_NAME"

    # 密码：必须是 bcrypt 哈希（$2a$ / $2b$ / $2y$）；不合法循环重问
    while :; do
        prompt_to MP_AGH_PASSWORD "$MP_AGH_PASSWORD" \
            "[5/7] AdGuardHome 管理员密码（bcrypt 哈希，\$2a\$/\$2y\$ 开头）" \
            "生成: htpasswd -bnBC 10 '' '明文' | cut -d: -f2     # apache2-utils" \
            "      mkpasswd -m bcrypt-a '明文'                    # Debian: apt install whois" \
            "      python3 -c \"import bcrypt;print(bcrypt.hashpw(b'明文',bcrypt.gensalt(10)).decode())\""
        case "$MP_AGH_PASSWORD" in
            '$2a$'*|'$2b$'*|'$2y$'*) break ;;
            '') say_err "      错误：不能为空。" ;;
            *)  say_err "      错误：必须是 bcrypt 哈希（\$2a\$/\$2b\$/\$2y\$ 开头）。" ;;
        esac
    done

    : "${MP_LOCAL_DNS:=223.5.5.5 114.114.114.114}"
    prompt_to MP_LOCAL_DNS "$MP_LOCAL_DNS" "[6/7] AGH 上游 DNS / MP_LOCAL_DNS"
else
    # 非交互：env.local.conf 必须已具备必填项
    : "${MP_REPO_RAW_URL:=https://raw.githubusercontent.com/AfxMsgBox/MyRule/main}"
    miss=
    [ -n "$MP_SUBSCRIBE_URL" ] || miss="$miss MP_SUBSCRIBE_URL"
    [ -n "$MP_AGH_USER_NAME" ] || miss="$miss MP_AGH_USER_NAME"
    [ -n "$MP_AGH_PASSWORD" ] || miss="$miss MP_AGH_PASSWORD"
    [ -z "$miss" ] || { echo "无 tty 且 env.local.conf 缺：$miss" >&2; exit 1; }
fi

# === 写 env.local.conf ===
# upsert_conf <key> <value> <file>：已存在则替换，否则追加。
# 值用单引号包裹防止 $ 被 source 时再次展开（bcrypt 哈希含 $）；
# 值里出现的单引号转义为 '\''
upsert_conf() {
    _uc_key=$1; _uc_val=$2; _uc_file=$3
    _uc_esc=$(printf '%s' "$_uc_val" | sed "s/'/'\\\\''/g")
    _uc_line="$_uc_key='$_uc_esc'"
    if grep -q "^$_uc_key=" "$_uc_file" 2>/dev/null; then
        awk -v k="$_uc_key" -v repl="$_uc_line" '
            $0 ~ "^" k "=" { print repl; next }
            { print }
        ' "$_uc_file" > "$_uc_file.tmp" && mv "$_uc_file.tmp" "$_uc_file"
    else
        printf '%s\n' "$_uc_line" >> "$_uc_file"
    fi
}

say_section "写入 env.local.conf"
say_dim "$DIR_SH/env.local.conf"
[ -f "$DIR_SH/env.local.conf" ] || : > "$DIR_SH/env.local.conf"
# tty 路径多写代理选择两条；非 tty 路径走 env.conf 默认 / 调用方预设
kv_keys="MP_INST_DIR MP_REPO_RAW_URL MP_SUBSCRIBE_URL MP_AGH_USER_NAME MP_AGH_PASSWORD MP_LOCAL_DNS"
[ "$HAVE_TTY" = "1" ] && kv_keys="$kv_keys MP_USE_PROXY MP_PROXY_HTTP"
for kv_key in $kv_keys; do
    eval "kv_val=\$$kv_key"
    [ "$kv_key" = "MP_INST_DIR" ] && kv_val="$DIR_INST"
    upsert_conf "$kv_key" "$kv_val" "$DIR_SH/env.local.conf"
done

# === Bootstrap：先 wget 拿到 env.conf + common.sh，足以 source 后用 mp_fetch_repo_sh ===
say_section "Bootstrap"
say_step "下载 env.conf / common.sh"
wget -q -O "$DIR_SH/env.conf"  "$MP_REPO_RAW_URL/sh/env.conf"  || { say_err "下载 env.conf 失败"  >&2; exit 1; }
wget -q -O "$DIR_SH/common.sh" "$MP_REPO_RAW_URL/sh/common.sh" || { say_err "下载 common.sh 失败" >&2; exit 1; }

export MP_INST_DIR="$DIR_INST"            # 显式声明根（init.d/$0 不可靠）
. "$DIR_SH/common.sh"                     # 加载公共函数

# === 用 tarball 一次拉齐 sh/ 整树（含 env.conf / common.sh / 所有 *.sh / sh/etc/*）===
# 覆盖刚 bootstrap 的 2 个文件无害；env.local.conf 不在 tarball 里所以不会动
say_step "拉取仓库 sh/ 整树"
mp_fetch_repo_sh "$DIR_SH" || { say_err "tarball 下载失败"; exit 1; }

# === sh/etc 路径占位替换（先只 sed-patch，是否 cp 到 /etc 由后面 autostart 决定） ===
etc_rels=$(mp_etc_rels)
say_step "sh/etc 路径替换 /etc/proxy → $DIR_INST"
for rel in $etc_rels; do
    [ -f "$DIR_SH/etc/$rel" ] && sed -i "s|/etc/proxy|$DIR_INST|g" "$DIR_SH/etc/$rel"
    chmod +x "$DIR_SH/etc/$rel" 2>/dev/null || true
done

# === 下载内核二进制（mihomo / AdGuardHome）===
say_section "下载内核二进制"
sh "$DIR_SH/update-bin.sh" || say_warn "（二进制更新有失败项，详见上方日志）"

# === 渲染 agh.yaml：拉模板 + mp_render_template ===
say_section "渲染 AGH 配置"
say_dim "$MP_AGH_DIR/agh.yaml"
agh_tpl=$(mktemp)
if download_file "$MP_URL_AGH_CONFIG" "$agh_tpl"; then
    mp_render_template "$agh_tpl" "$MP_AGH_DIR/agh.yaml"
    say_ok "agh.yaml 已生成"
else
    say_err "下载 agh.yaml 模板失败"
fi
rm -f "$agh_tpl"

# === 刷新 AGH dns.conf 与 core/config.yaml（不跑 update-proxy-rule.sh：mihomo 还没起）===
say_section "刷新 AGH dns.conf 与 core/config.yaml"
sh "$DIR_SH/update-agh-config.sh"  || say_warn "（AGH dns.conf 有失败项）"
sh "$DIR_SH/update-core-config.sh" || say_warn "（core config.yaml 有失败项）"

# === [7/7] 自启动询问 ===
# Y：把 $DIR_SH/etc 下文件复制到 /etc 对应位置并 enable+start
# n：不动 /etc；服务文件留在 $DIR_SH/etc，可后续手动 cp 或重跑 inst 选 Y
prompt_to autostart "Y" "[7/7] 现在启用并启动系统服务？(Y/n)" \
    "Y = 把 $DIR_SH/etc 下文件复制到 /etc 对应位置，并 enable + start" \
    "n = 跳过；服务文件留在 $DIR_SH/etc，可后续按下面命令手动装"

case "$autostart" in
    n|N|no|NO|No)
        say_section "已跳过自启动"
        say_dim "服务文件保留在 $DIR_SH/etc/；手动启用："
        case "$MP_OS_TYPE" in
            openwrt)
                for rel in $etc_rels; do
                    say_dim "  cp $DIR_SH/etc/$rel  /etc/$rel  && chmod +x /etc/$rel"
                done
                say_dim "  service proxy_core enable && service proxy_core start"
                say_dim "  service agh enable && service agh start"
                ;;
            systemd)
                for rel in $etc_rels; do
                    say_dim "  cp $DIR_SH/etc/$rel  /etc/$rel"
                done
                say_dim "  systemctl daemon-reload && systemctl enable --now proxy_core.service agh.service"
                ;;
        esac
        ;;
    *)
        say_section "安装服务文件到 /etc 并启动"
        for rel in $etc_rels; do
            mkdir -p "/etc/$(dirname "$rel")"
            cp "$DIR_SH/etc/$rel" "/etc/$rel"
            chmod +x "/etc/$rel" 2>/dev/null || true
        done
        [ "$MP_OS_TYPE" = "systemd" ] && systemctl daemon-reload
        mp_service_op enable_start proxy_core agh

        # mihomo API 起来后补跑订阅/规则集刷新；失败不影响安装结束
        say_step "等待 mihomo API 就绪后刷新订阅与规则集"
        sleep 3
        sh "$DIR_SH/update-proxy-rule.sh" || say_warn "（订阅/规则集刷新失败，可稍后手动跑 update-proxy-rule.sh）"
        ;;
esac

say_section "安装完成"
printf '%s  %s\n' "${C_B}安装目录${C_R}" "$DIR_INST"
printf '%s  %s%s%s   用户名 %s\n' "${C_B}AGH Web ${C_R}" "${C_CYN}" "http://<本机IP>:180" "${C_R}" "$MP_AGH_USER_NAME"
case "$MP_OS_TYPE" in
    openwrt) printf '%s  %slogread -e MyProxy -f%s\n' "${C_B}日志    ${C_R}" "${C_D}" "${C_R}" ;;
    systemd) printf '%s  %sjournalctl -t MyProxy -f%s\n' "${C_B}日志    ${C_R}" "${C_D}" "${C_R}" ;;
esac
printf '\n%s\n' "${C_B}以后刷新${C_R}"
say_dim "  脚本:   sh $DIR_SH/update-scripts.sh"
say_dim "  配置:   sh $DIR_SH/update-all-configs.sh   # 或单独跑 update-{agh,core,proxy-rule}-config.sh"
say_dim "  二进制: sh $DIR_SH/update-bin.sh"
