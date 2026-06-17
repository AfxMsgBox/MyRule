#!/bin/sh
# MyProxy 一键安装：交互式收集敏感参数 → 下载脚本/服务文件/二进制 → 渲染配置 → 启动服务。
#
# 用法（需 root；安装根目录作为第一个参数，省略则用 $PWD）：
#   mkdir -p /opt/myproxy && cd $_ && sh inst.sh        # 装到 /opt/myproxy/{sh,core,agh}
#   sh inst.sh /etc/proxy                                # 显式指定，装到 /etc/proxy/{sh,core,agh}
# wget|sh 管道（交互向导从 /dev/tty 读取输入，不会读到脚本本身）：
#   mkdir -p /opt/myproxy && cd $_
#   wget -O- https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/inst.sh | sh
# 自托管 / 分支调试：
#   MP_REPO_RAW_URL=https://raw.githubusercontent.com/AfxMsgBox/MyRule/refs/heads/<branch> \
#       wget -O- "$MP_REPO_RAW_URL/sh/inst.sh" | sh

# 必须 root 才能写 /etc/init.d、/etc/systemd/system 等
[ "$(id -u)" = "0" ] || { echo "需要 root 权限运行（Debian/Ubuntu 请加 sudo）" >&2; exit 1; }

# === 路径解析：第一个位置参数 = 安装根，省略则用 $PWD ===
DIR_INST="${1:-$PWD}"
DIR_SH="$DIR_INST/sh"
DIR_CORE="$DIR_INST/core"
DIR_AGH="$DIR_INST/agh"
mkdir -p "$DIR_SH" "$DIR_CORE" "$DIR_AGH"

# === OS 识别：openwrt | systemd，可通过 OS_TYPE 强制 ===
if [ -n "$OS_TYPE" ]; then
    :
elif [ -f /etc/openwrt_release ] || grep -qs '^ID=.*openwrt' /etc/os-release; then
    OS_TYPE=openwrt
elif command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ]; then
    OS_TYPE=systemd
else
    echo "未识别的系统；用 OS_TYPE=openwrt 或 OS_TYPE=systemd 强制" >&2
    exit 1
fi

echo "目标系统：$OS_TYPE"
echo "安装根目录：$DIR_INST"
echo "  → 脚本: $DIR_SH"
echo "  → core: $DIR_CORE"
echo "  → agh:  $DIR_AGH"
echo

# === 预加载已有 env.local.conf（重装场景的默认值来源） ===
[ -f "$DIR_SH/env.local.conf" ] && . "$DIR_SH/env.local.conf"

# === 交互向导：能读到 /dev/tty 就开问，否则跳过用现有值 ===
HAVE_TTY=0
{ : >/dev/tty; } 2>/dev/null && [ -r /dev/tty ] && HAVE_TTY=1

# prompt_to <var> <default> <label> [hint_lines...]
# - HAVE_TTY=0 时直接把 default 赋给 var，不打印
# - HAVE_TTY=1 时显示 label / 可选 hint / [default]，回车保留默认
prompt_to() {
    _p_var=$1; _p_def=$2; _p_label=$3
    shift 3
    [ "$HAVE_TTY" = "1" ] || { eval "$_p_var=\$_p_def"; return; }
    printf '%s\n' "$_p_label" >/dev/tty
    for _p_hint in "$@"; do printf '      %s\n' "$_p_hint" >/dev/tty; done
    if [ -n "$_p_def" ]; then
        printf '      [%s]\n' "$_p_def" >/dev/tty
    else
        printf '      <空>\n' >/dev/tty
    fi
    printf '      > ' >/dev/tty
    IFS= read -r _p_val </dev/tty || _p_val=""
    [ -n "$_p_val" ] || _p_val="$_p_def"
    eval "$_p_var=\$_p_val"
}

# 输入 main / 分支名（含 / 也行）自动拼成 raw URL；输入完整 URL 则原样保留
expand_branch() {
    case "$1" in
        http://*|https://*) printf '%s' "$1" ;;
        *) printf 'https://raw.githubusercontent.com/AfxMsgBox/MyRule/refs/heads/%s' "$1" ;;
    esac
}

if [ "$HAVE_TTY" = "1" ]; then
    # 显示当前分支（从已有 URL 反推；main 默认仓库则显示 "main"）
    _cur_branch=
    case "$MP_REPO_RAW_URL" in
        */refs/heads/*) _cur_branch="${MP_REPO_RAW_URL##*/refs/heads/}" ;;
        */main|"")      _cur_branch="main" ;;
        *)              _cur_branch="$MP_REPO_RAW_URL" ;;
    esac

    prompt_to in_branch  "$_cur_branch"      "[1/5] 仓库分支（输入分支名自动拼 raw URL，或粘贴完整 URL）"
    case "$in_branch" in
        main|"") MP_REPO_RAW_URL="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main" ;;
        *)       MP_REPO_RAW_URL=$(expand_branch "$in_branch") ;;
    esac

    prompt_to MP_SUBSCRIBE_URL "$MP_SUBSCRIBE_URL" "[2/5] 节点订阅 URL / MP_SUBSCRIBE_URL"
    prompt_to MP_AGH_USER_NAME "$MP_AGH_USER_NAME" "[3/5] AdGuardHome 管理员用户名 / MP_AGH_USER_NAME"

    # 密码：必须是 bcrypt 哈希（$2a$ / $2b$ / $2y$ 开头）；不合法循环重问
    while :; do
        prompt_to MP_AGH_PASSWORD "$MP_AGH_PASSWORD" \
            "[4/5] AdGuardHome 管理员密码（bcrypt 哈希，\$2a\$/\$2y\$ 开头）" \
            "生成: htpasswd -bnBC 10 '' '明文' | cut -d: -f2     # apache2-utils" \
            "      mkpasswd -m bcrypt-a '明文'                    # Debian: apt install whois" \
            "      python3 -c \"import bcrypt;print(bcrypt.hashpw(b'明文',bcrypt.gensalt(10)).decode())\""
        case "$MP_AGH_PASSWORD" in
            '$2a$'*|'$2b$'*|'$2y$'*) break ;;
            '') echo "      错误：不能为空。" >/dev/tty ;;
            *)  echo "      错误：必须是 bcrypt 哈希（以 \$2a\$/\$2b\$/\$2y\$ 开头）。" >/dev/tty ;;
        esac
    done

    : "${MP_LOCAL_DNS:=223.5.5.5 114.114.114.114}"
    prompt_to MP_LOCAL_DNS    "$MP_LOCAL_DNS"     "[5/5] AGH 上游 DNS / MP_LOCAL_DNS"

    echo
else
    # 非交互：要求 env.local.conf 已具备必填项
    : "${MP_REPO_RAW_URL:=https://raw.githubusercontent.com/AfxMsgBox/MyRule/main}"
    miss=
    [ -n "$MP_SUBSCRIBE_URL" ] || miss="$miss MP_SUBSCRIBE_URL"
    [ -n "$MP_AGH_USER_NAME" ] || miss="$miss MP_AGH_USER_NAME"
    [ -n "$MP_AGH_PASSWORD" ] || miss="$miss MP_AGH_PASSWORD"
    [ -z "$miss" ] || { echo "无 tty 且 env.local.conf 缺：$miss" >&2; exit 1; }
fi

# === 写 env.local.conf ===
# upsert_conf <key> <value> <file>：已存在则替换，否则追加。
# 值用单引号包裹（防止 $ 被 source 重新展开 —— bcrypt 哈希含 $）；
# 值里出现的单引号用标准 sh 转义 '\''
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
upsert_conf MP_INST_DIR       "$DIR_INST"        "$DIR_SH/env.local.conf"
upsert_conf MP_REPO_RAW_URL   "$MP_REPO_RAW_URL" "$DIR_SH/env.local.conf"
upsert_conf MP_SUBSCRIBE_URL  "$MP_SUBSCRIBE_URL" "$DIR_SH/env.local.conf"
upsert_conf MP_AGH_USER_NAME  "$MP_AGH_USER_NAME" "$DIR_SH/env.local.conf"
upsert_conf MP_AGH_PASSWORD   "$MP_AGH_PASSWORD"  "$DIR_SH/env.local.conf"
upsert_conf MP_LOCAL_DNS      "$MP_LOCAL_DNS"     "$DIR_SH/env.local.conf"

# === 引导下载 env.conf 与 common.sh（按用户选的 MP_REPO_RAW_URL） ===
echo ">>> 引导下载 env.conf / common.sh"
wget -q -O "$DIR_SH/env.conf"  "$MP_REPO_RAW_URL/sh/env.conf"  || { echo "下载 env.conf 失败"  >&2; exit 1; }
wget -q -O "$DIR_SH/common.sh" "$MP_REPO_RAW_URL/sh/common.sh" || { echo "下载 common.sh 失败" >&2; exit 1; }

# 告诉后续脚本不要再下 env.conf / common.sh
export _DEPS_UPDATED=1
# 显式声明安装根（init.d/$0 不可靠 + inst.sh 自身路径不固定）
export MP_INST_DIR="$DIR_INST"
# 加载 env + 公共函数；不设 url_self，common.sh 自动跳过自更新
. "$DIR_SH/common.sh"

# === 下载其余公共脚本 ===
echo_log ">>> 下载脚本到 $DIR_SH"
for name in keeplive.sh setup-fake-ip-route.sh \
            update-agh-config.sh update-all-configs.sh \
            update-all-configs-restart-services.sh update-bin.sh \
            update-core-config.sh update-proxy-rule.sh inst.sh; do
    download_file "$MP_REPO_RAW_URL/sh/$name" "$DIR_SH/$name" true 0 \
        || { echo_log "下载 $name 失败"; exit 1; }
done
chmod +x "$DIR_SH"/*.sh

# === 按 OS 装服务文件，并把 /etc/proxy 占位统一替换为实际安装根 ===
echo_log ">>> 安装平台服务文件（路径替换 /etc/proxy → $DIR_INST）"
patch_paths() { sed -i "s|/etc/proxy|$DIR_INST|g" "$1"; }
case "$OS_TYPE" in
    openwrt)
        for f in init.d/proxy_core init.d/agh hotplug.d/net/99-meta-route; do
            download_file "$MP_REPO_RAW_URL/sh/etc/$f" "/etc/$f" true 0 \
                || { echo_log "下载 $f 失败"; exit 1; }
            patch_paths "/etc/$f"
            chmod +x "/etc/$f"
        done
        ;;
    systemd)
        for f in proxy_core.service agh.service; do
            download_file "$MP_REPO_RAW_URL/sh/etc/systemd/system/$f" "/etc/systemd/system/$f" true 0 \
                || { echo_log "下载 $f 失败"; exit 1; }
            patch_paths "/etc/systemd/system/$f"
        done
        systemctl daemon-reload
        ;;
esac

# === 下载内核二进制（实际工作放在 update-bin.sh 里，便于以后单独升级） ===
sh "$DIR_SH/update-bin.sh" || echo_log "（二进制更新有失败项，详见上方日志）"

# === 渲染 agh.yaml：拉取模板，把 {MP_*} 占位符按当前环境替换 ===
echo_log ">>> 渲染 AGH 配置 → $MP_AGH_DIR/agh.yaml"
agh_tpl=$(mktemp)
if download_file "$MP_URL_AGH_CONFIG" "$agh_tpl" true 0; then
    # 复用 update-core-config.sh 的 awk ENVIRON 替换法；MP_* 已被 env.conf set -a 自动 export
    awk '{
        out = ""
        while (match($0, /\{MP_[A-Za-z0-9_]+\}/)) {
            ph  = substr($0, RSTART, RLENGTH)
            key = substr(ph, 2, RLENGTH - 2)
            repl = (key in ENVIRON) ? ENVIRON[key] : ph
            out = out substr($0, 1, RSTART - 1) repl
            $0 = substr($0, RSTART + RLENGTH)
        }
        print out $0
    }' "$agh_tpl" > "$MP_AGH_DIR/agh.yaml.tmp" \
        && mv "$MP_AGH_DIR/agh.yaml.tmp" "$MP_AGH_DIR/agh.yaml"
    echo_log "agh.yaml 已生成"
else
    echo_log "下载 agh.yaml 模板失败"
fi
rm -f "$agh_tpl"

# === 刷新 AGH dns.conf 与 core/config.yaml ===
echo_log ">>> 刷新 AGH dns.conf 与 core/config.yaml"
sh "$DIR_SH/update-all-configs.sh" || echo_log "（部分步骤失败，详见上方日志）"

# === 启用并启动服务（任一步失败仅警告，不中断 inst） ===
echo_log ">>> 启用并启动服务"
case "$OS_TYPE" in
    openwrt)
        service proxy_core enable && service proxy_core start || echo_log "proxy_core 启动失败"
        service agh enable && service agh start || echo_log "agh 启动失败"
        ;;
    systemd)
        systemctl enable --now proxy_core.service || echo_log "proxy_core 启动失败"
        systemctl enable --now agh.service || echo_log "agh 启动失败"
        ;;
esac

echo
echo "============ 安装完成 ============"
echo "  安装目录：$DIR_INST"
echo "  AGH Web：http://<本机IP>:180   用户名 $MP_AGH_USER_NAME"
case "$OS_TYPE" in
    openwrt) echo "  日志：logread -e MyProxy -f" ;;
    systemd) echo "  日志：journalctl -t MyProxy -f" ;;
esac
