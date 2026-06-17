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

echo "目标系统：$MP_OS_TYPE"
echo "安装根目录：$DIR_INST"
echo "  → 脚本: $DIR_SH        (含 sh/etc/ 下的服务文件副本)"
echo "  → core: $DIR_CORE"
echo "  → agh:  $DIR_AGH"
echo

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
    printf '%s\n' "$_p_label" >/dev/tty
    for _p_hint in "$@"; do printf '      %s\n' "$_p_hint" >/dev/tty; done
    if [ -n "$_p_def" ]; then
        printf '      [%s]\n      > ' "$_p_def" >/dev/tty
    else
        printf '      <空>\n      > ' >/dev/tty
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

    prompt_to in_branch "$cur_branch" "[1/6] 仓库分支（分支名自动拼 raw URL，或粘贴完整 URL）"
    MP_REPO_RAW_URL=$(expand_branch "$in_branch")

    prompt_to MP_SUBSCRIBE_URL "$MP_SUBSCRIBE_URL" "[2/6] 节点订阅 URL / MP_SUBSCRIBE_URL"
    prompt_to MP_AGH_USER_NAME "$MP_AGH_USER_NAME" "[3/6] AdGuardHome 管理员用户名 / MP_AGH_USER_NAME"

    # 密码：必须是 bcrypt 哈希（$2a$ / $2b$ / $2y$）；不合法循环重问
    while :; do
        prompt_to MP_AGH_PASSWORD "$MP_AGH_PASSWORD" \
            "[4/6] AdGuardHome 管理员密码（bcrypt 哈希，\$2a\$/\$2y\$ 开头）" \
            "生成: htpasswd -bnBC 10 '' '明文' | cut -d: -f2     # apache2-utils" \
            "      mkpasswd -m bcrypt-a '明文'                    # Debian: apt install whois" \
            "      python3 -c \"import bcrypt;print(bcrypt.hashpw(b'明文',bcrypt.gensalt(10)).decode())\""
        case "$MP_AGH_PASSWORD" in
            '$2a$'*|'$2b$'*|'$2y$'*) break ;;
            '') echo "      错误：不能为空。" >/dev/tty ;;
            *)  echo "      错误：必须是 bcrypt 哈希（\$2a\$/\$2b\$/\$2y\$ 开头）。" >/dev/tty ;;
        esac
    done

    : "${MP_LOCAL_DNS:=223.5.5.5 114.114.114.114}"
    prompt_to MP_LOCAL_DNS "$MP_LOCAL_DNS" "[5/6] AGH 上游 DNS / MP_LOCAL_DNS"
    echo
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

echo ">>> 写入 $DIR_SH/env.local.conf"
[ -f "$DIR_SH/env.local.conf" ] || : > "$DIR_SH/env.local.conf"
for kv_key in MP_INST_DIR MP_REPO_RAW_URL MP_SUBSCRIBE_URL MP_AGH_USER_NAME MP_AGH_PASSWORD MP_LOCAL_DNS; do
    eval "kv_val=\$$kv_key"
    [ "$kv_key" = "MP_INST_DIR" ] && kv_val="$DIR_INST"
    upsert_conf "$kv_key" "$kv_val" "$DIR_SH/env.local.conf"
done

# === Bootstrap：先按选定 MP_REPO_RAW_URL 下 env.conf / common.sh ===
echo ">>> 引导下载 env.conf / common.sh"
wget -q -O "$DIR_SH/env.conf"  "$MP_REPO_RAW_URL/sh/env.conf"  || { echo "下载 env.conf 失败"  >&2; exit 1; }
wget -q -O "$DIR_SH/common.sh" "$MP_REPO_RAW_URL/sh/common.sh" || { echo "下载 common.sh 失败" >&2; exit 1; }

export MP_INST_DIR="$DIR_INST"            # 显式声明根（init.d/$0 不可靠）
. "$DIR_SH/common.sh"                     # 加载公共函数

# === 下载其余公共脚本（含 update-scripts.sh：以后刷新脚本就靠它） ===
echo_log ">>> 下载脚本到 $DIR_SH"
for name in keeplive.sh setup-fake-ip-route.sh \
            update-scripts.sh update-bin.sh \
            update-all-configs.sh update-all-configs-restart-services.sh \
            update-agh-config.sh update-core-config.sh update-proxy-rule.sh \
            inst.sh; do
    download_file "$MP_REPO_RAW_URL/sh/$name" "$DIR_SH/$name" true 0 \
        || { echo_log "下载 $name 失败"; exit 1; }
done
chmod +x "$DIR_SH"/*.sh

# === 下载服务文件到 $DIR_SH/etc/（先把 /etc/proxy 占位换成实际 $DIR_INST） ===
# 注：以后 update-scripts.sh 也会同时刷新这里的副本；若已选过自启动，会同步覆盖 /etc 下副本
case "$MP_OS_TYPE" in
    openwrt) etc_rels="init.d/proxy_core init.d/agh hotplug.d/net/99-meta-route" ;;
    systemd) etc_rels="systemd/system/proxy_core.service systemd/system/agh.service" ;;
esac
echo_log ">>> 下载服务文件到 $DIR_SH/etc（路径替换 /etc/proxy → $DIR_INST）"
for rel in $etc_rels; do
    mkdir -p "$DIR_SH/etc/$(dirname "$rel")"
    download_file "$MP_REPO_RAW_URL/sh/etc/$rel" "$DIR_SH/etc/$rel" true 0 \
        || { echo_log "下载 $rel 失败"; exit 1; }
    sed -i "s|/etc/proxy|$DIR_INST|g" "$DIR_SH/etc/$rel"
    chmod +x "$DIR_SH/etc/$rel" 2>/dev/null || true
done

# === 下载内核二进制（mihomo / AdGuardHome）===
sh "$DIR_SH/update-bin.sh" || echo_log "（二进制更新有失败项，详见上方日志）"

# === 渲染 agh.yaml：拉模板 + mp_render_template ===
echo_log ">>> 渲染 AGH 配置 → $MP_AGH_DIR/agh.yaml"
agh_tpl=$(mktemp)
if download_file "$MP_URL_AGH_CONFIG" "$agh_tpl" true 0; then
    mp_render_template "$agh_tpl" "$MP_AGH_DIR/agh.yaml"
    echo_log "agh.yaml 已生成"
else
    echo_log "下载 agh.yaml 模板失败"
fi
rm -f "$agh_tpl"

# === 刷新 AGH dns.conf 与 core/config.yaml ===
echo_log ">>> 刷新 AGH dns.conf 与 core/config.yaml"
sh "$DIR_SH/update-all-configs.sh" || echo_log "（部分步骤失败，详见上方日志）"

# === [6/6] 自启动询问 ===
# Y：把 $DIR_SH/etc 下文件复制到 /etc 对应位置并 enable+start
# n：不动 /etc；服务文件留在 $DIR_SH/etc，可后续手动 cp 或重跑 inst 选 Y
prompt_to autostart "Y" "[6/6] 现在启用并启动系统服务？(Y/n)" \
    "Y = 把 $DIR_SH/etc 下文件复制到 /etc 对应位置，并 enable + start" \
    "n = 跳过；服务文件留在 $DIR_SH/etc，可后续按下面命令手动装"

case "$autostart" in
    n|N|no|NO|No)
        echo_log ">>> 已跳过自启动；服务文件保留在 $DIR_SH/etc/"
        echo_log "    手动启用命令："
        case "$MP_OS_TYPE" in
            openwrt)
                for rel in $etc_rels; do
                    echo_log "      cp $DIR_SH/etc/$rel  /etc/$rel  && chmod +x /etc/$rel"
                done
                echo_log "      service proxy_core enable && service proxy_core start"
                echo_log "      service agh enable && service agh start"
                ;;
            systemd)
                for rel in $etc_rels; do
                    echo_log "      cp $DIR_SH/etc/$rel  /etc/$rel"
                done
                echo_log "      systemctl daemon-reload && systemctl enable --now proxy_core.service agh.service"
                ;;
        esac
        ;;
    *)
        echo_log ">>> 安装服务文件到 /etc 并启动"
        for rel in $etc_rels; do
            mkdir -p "/etc/$(dirname "$rel")"
            cp "$DIR_SH/etc/$rel" "/etc/$rel"
            chmod +x "/etc/$rel" 2>/dev/null || true
        done
        [ "$MP_OS_TYPE" = "systemd" ] && systemctl daemon-reload
        mp_service_op enable_start proxy_core agh
        ;;
esac

echo
echo "============ 安装完成 ============"
echo "  安装目录: $DIR_INST"
echo "  AGH Web:  http://<本机IP>:180   用户名 $MP_AGH_USER_NAME"
case "$MP_OS_TYPE" in
    openwrt) echo "  日志:     logread -e MyProxy -f" ;;
    systemd) echo "  日志:     journalctl -t MyProxy -f" ;;
esac
echo "  以后刷新："
echo "    脚本:   sh $DIR_SH/update-scripts.sh"
echo "    配置:   sh $DIR_SH/update-all-configs.sh   # 或单独跑 update-{agh,core,proxy-rule}-config.sh"
echo "    二进制: sh $DIR_SH/update-bin.sh"
