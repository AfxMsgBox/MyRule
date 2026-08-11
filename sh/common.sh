#!/bin/sh
# 公共函数库。被各脚本 source 加载 env.conf + 提供工具函数。
# 不再做"任何"自更新；需要刷新脚本本身请显式跑 update-scripts.sh。
# 命名约定：MP_* 全局；小写本地。

# 通过脚本路径反推 $MP_INST_DIR（脚本约定在 sh/ 子目录，所以根 = ../..）
# 让 init.d/$0 不可靠的场景也能定位 env.conf 与 env.local.conf
_path_self=$(readlink -f "$0" 2>/dev/null || echo "$0")
MP_INST_DIR="${MP_INST_DIR:-$(dirname "$(dirname "$_path_self")")}"

if [ -f "$MP_INST_DIR/sh/env.conf" ]; then
    . "$MP_INST_DIR/sh/env.conf"
elif [ -f /etc/proxy/sh/env.conf ]; then
    . /etc/proxy/sh/env.conf
else
    echo "缺少 env.conf" >&2; exit 1
fi

# 日志：终端 + 系统 log
echo_log() {
    echo "$1"
    logger -t MyProxy -- "$1" 2>/dev/null || :
}

# 文件字节数；不存在返回 0
get_file_size() {
    [ -f "$1" ] && wc -c < "$1" | tr -d ' \n' || echo 0
}

# mp_core_value <top-section-or-empty> <key> [config]
# 读取 Core YAML 的顶层标量，或顶层 section 下的直接子标量。
# 这是有意受限的解析器：只处理本项目需要的简单 key: value，不冒充完整 YAML。
mp_core_value() {
    _mcv_section="$1"; _mcv_key="$2"
    _mcv_config="${3:-$MP_CORE_DIR/config.yaml}"
    [ -f "$_mcv_config" ] || return 1
    awk -v section="$_mcv_section" -v key="$_mcv_key" '
    BEGIN { child_indent = -1 }
    function clean(v) {
        sub(/^[[:space:]]+/, "", v)
        sub(/[[:space:]]+$/, "", v)
        sub(/[[:space:]]+#.*/, "", v)
        if ((substr(v, 1, 1) == "\"" && substr(v, length(v), 1) == "\"") ||
            (substr(v, 1, 1) == "\047" && substr(v, length(v), 1) == "\047")) {
            v = substr(v, 2, length(v) - 2)
        }
        return v
    }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    {
        match($0, /^[[:space:]]*/); indent = RLENGTH
        line = $0; sub(/^[[:space:]]+/, "", line)
    }
    section == "" && indent == 0 && index(line, key ":") == 1 {
        value = substr(line, length(key) + 2)
        print clean(value); found = 1; exit
    }
    section != "" && !in_section && indent == 0 && line ~ ("^" section ":[[:space:]]*($|#)") {
        in_section = 1; section_indent = indent; next
    }
    in_section {
        if (indent <= section_indent) exit
        if (child_indent < 0) child_indent = indent
        if (indent == child_indent && index(line, key ":") == 1) {
            value = substr(line, length(key) + 2)
            print clean(value); found = 1; exit
        }
    }
    END { if (!found) exit 1 }
    ' "$_mcv_config"
}

_mp_valid_port() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 65535 ]
}

# Core 本机代理。style=curl（默认）使用 socks5h 远端解析；style=agh 输出 AGH 支持的 scheme。
# mp_core_proxy_url [config] [curl|agh]
mp_core_proxy_url() {
    _mcp_config="${1:-$MP_CORE_DIR/config.yaml}"
    _mcp_style="${2:-curl}"
    case "$_mcp_style" in curl|agh) ;; *) return 1 ;; esac
    for _mcp_key in mixed-port port socks-port; do
        _mcp_port=$(mp_core_value "" "$_mcp_key" "$_mcp_config" 2>/dev/null || :)
        _mp_valid_port "$_mcp_port" || continue
        case "$_mcp_key:$_mcp_style" in
            mixed-port:curl|socks-port:curl)
                printf 'socks5h://127.0.0.1:%s\n' "$_mcp_port"
                ;;
            socks-port:agh)
                printf 'socks5://127.0.0.1:%s\n' "$_mcp_port"
                ;;
            *)
                printf 'http://127.0.0.1:%s\n' "$_mcp_port"
                ;;
        esac
        return 0
    done
    return 1
}

# 把 :port / 0.0.0.0:port / [::]:port 转成本机可连接的 endpoint。
_mp_core_local_endpoint() {
    _mcle_addr="$1"
    case "$_mcle_addr" in
        \[*\]:*)
            _mcle_host=${_mcle_addr%%]*}; _mcle_host=${_mcle_host#\[}
            _mcle_port=${_mcle_addr##*:}
            ;;
        *:*)
            _mcle_host=${_mcle_addr%:*}; _mcle_port=${_mcle_addr##*:}
            ;;
        *) return 1 ;;
    esac
    _mp_valid_port "$_mcle_port" || return 1
    case "$_mcle_host" in ''|0.0.0.0|::) _mcle_host=127.0.0.1 ;; esac
    case "$_mcle_host" in *:*) printf '[%s]:%s\n' "$_mcle_host" "$_mcle_port" ;;
        *) printf '%s:%s\n' "$_mcle_host" "$_mcle_port" ;;
    esac
}

mp_core_api_url() {
    _mcau_config="${1:-$MP_CORE_DIR/config.yaml}"
    _mcau_addr=$(mp_core_value "" external-controller "$_mcau_config") || return 1
    _mcau_endpoint=$(_mp_core_local_endpoint "$_mcau_addr") || return 1
    printf 'http://%s\n' "$_mcau_endpoint"
}

mp_core_dns_endpoint() {
    _mcde_config="${1:-$MP_CORE_DIR/config.yaml}"
    _mcde_addr=$(mp_core_value dns listen "$_mcde_config") || return 1
    _mp_core_local_endpoint "$_mcde_addr"
}

# 读取 dns.fake-ip-range 并规范化为 IPv4 网络 CIDR。
mp_core_fake_ip_cidr() {
    _mcfic_config="${1:-$MP_CORE_DIR/config.yaml}"
    _mcfic_range=$(mp_core_value dns fake-ip-range "$_mcfic_config") || return 1
    printf '%s\n' "$_mcfic_range" | awk -F/ '
        function fail() { exit 1 }
        NF != 2 || $2 !~ /^[0-9]+$/ || $2 < 0 || $2 > 32 { fail() }
        {
            n = split($1, octet, ".")
            if (n != 4) fail()
            for (i = 1; i <= 4; i++) {
                if (octet[i] !~ /^[0-9]+$/ || octet[i] < 0 || octet[i] > 255) fail()
                ip = ip * 256 + octet[i]
            }
            host_bits = 32 - $2
            block = 2 ^ host_bits
            network = int(ip / block) * block
            a = int(network / 16777216); network %= 16777216
            b = int(network / 65536);    network %= 65536
            c = int(network / 256);      d = network % 256
            printf "%d.%d.%d.%d/%d\n", a, b, c, d, $2
        }
    '
}

# external-ui 只允许 Core home 内的相对目录，避免更新脚本删除任意路径。
mp_core_external_ui_path() {
    _mceu_config="${1:-$MP_CORE_DIR/config.yaml}"
    _mceu_rel=$(mp_core_value "" external-ui "$_mceu_config") || return 1
    while [ "${_mceu_rel#./}" != "$_mceu_rel" ]; do _mceu_rel=${_mceu_rel#./}; done
    case "$_mceu_rel" in ''|.|..|/*|../*|*/../*|*/..) return 1 ;; esac
    printf '%s/%s\n' "$MP_CORE_DIR" "$_mceu_rel"
}

# 有交互终端时询问是否重试；回车默认重试。无终端或明确拒绝时返回失败。
download_retry_prompt() {
    if { : >/dev/tty; } 2>/dev/null && [ -r /dev/tty ]; then
        printf '下载失败，是否重试？[Y/n] ' >/dev/tty
        IFS= read -r _drp_retry </dev/tty || _drp_retry=n
        case "$_drp_retry" in n|N|no|NO|No) return 1 ;; *) return 0 ;; esac
    fi
    return 1
}

# download_file <url> <dst> [verbose=true] [min_size=8]
# verbose=true 时额外输出 url、完成时的字节数与耗时
# 每轮依次尝试 Core 配置派生的本机代理、外部后备代理、直连。
# 一轮全失败时有 tty 则询问是否重试，否则直接返回失败。
# --fail 让 4xx/5xx 不被当成功；mktemp + mv 原子替换
download_file() {
    # 所有内部变量加 _df_ 前缀，避免污染调用方同名变量（POSIX sh 无 local）
    _df_url="$1"; _df_dst="$2"; _df_verbose="${3:-true}"
    _df_min_size="${4:-8}"
    [ "$_df_verbose" = "true" ] && echo_log "下载 $_df_url"
    _df_t0=$(date +%s)
    if [ "$_df_verbose" = "true" ] && [ -t 2 ]; then
        _df_display=--progress-bar
    else
        _df_display=--silent
    fi
    _df_dir=$(dirname "$_df_dst")
    mkdir -p "$_df_dir" || return 1
    # 临时文件放在目标目录，保证最后 mv 不跨文件系统，真正原子替换。
    _df_tmp=$(mktemp "$_df_dir/.download.XXXXXX") || return 1

    # _df_attempt <proxy-url-or-empty> <label>
    # 空 proxy 表示直连；成功且文件大小合格时返回 0。
    _df_attempt() {
        _df_attempt_proxy="$1"; _df_attempt_label="$2"
        [ "$_df_verbose" = "true" ] && echo_log "尝试：$_df_attempt_label"
        if [ -n "$_df_attempt_proxy" ]; then
            curl "$_df_display" --show-error --fail -L --connect-timeout 10 --max-time 300 \
                 --proxy "$_df_attempt_proxy" "$_df_url" -o "$_df_tmp"
        else
            curl "$_df_display" --show-error --fail -L --connect-timeout 10 --max-time 300 \
                 --noproxy '*' "$_df_url" -o "$_df_tmp"
        fi
        _df_rc=$?
        [ "$_df_rc" -eq 0 ] && [ "$(get_file_size "$_df_tmp")" -gt "$_df_min_size" ]
    }

    while :; do
        _df_primary_proxy=$(mp_core_proxy_url 2>/dev/null || :)
        _df_ok=0
        if [ -n "$_df_primary_proxy" ] && _df_attempt "$_df_primary_proxy" "Core 本机代理"; then
            _df_ok=1
        elif [ -n "$MP_PROXY" ] && [ "$MP_PROXY" != "$_df_primary_proxy" ] \
             && _df_attempt "$MP_PROXY" "外部后备代理"; then
            _df_ok=1
        fi
        if [ "$_df_ok" -eq 0 ] && _df_attempt "" "直连"; then
            _df_ok=1
        fi
        [ "$_df_ok" -eq 1 ] && break

        [ "$_df_verbose" = "true" ] && echo_log "下载失败"
        if ! download_retry_prompt; then
            rm -f "$_df_tmp"
            return 1
        fi
    done
    [ "$_df_verbose" = "true" ] && echo_log "完成：$(get_file_size "$_df_tmp") 字节 / $(($(date +%s) - _df_t0))s"
    mv "$_df_tmp" "$_df_dst"
}

# OS 探测：直接输出 openwrt/systemd，不保存全局状态。
mp_detect_os() {
    if [ -f /etc/openwrt_release ] || grep -qs '^ID=.*openwrt' /etc/os-release; then
        printf '%s\n' openwrt
    elif command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ]; then
        printf '%s\n' systemd
    else
        return 1
    fi
}

# mp_service_op <op> <svc...>   op: enable_start | restart | stop
# 按即时探测的系统类型派发到 service / systemctl。
mp_service_op() {
    _mso_os=$(mp_detect_os) || { echo_log "未识别系统，跳过 $*"; return 1; }
    _op=$1; shift
    _mso_rc=0
    for _svc in "$@"; do
        case "$_mso_os-$_op" in
            openwrt-enable_start) service "$_svc" enable && service "$_svc" start ;;
            openwrt-restart)      service "$_svc" restart ;;
            openwrt-stop)         service "$_svc" stop ;;
            systemd-enable_start) systemctl enable --now "$_svc.service" ;;
            systemd-restart)      systemctl restart "$_svc.service" ;;
            systemd-stop)         systemctl stop "$_svc.service" ;;
            *) echo_log "未支持的操作 $_mso_os-$_op"; return 1 ;;
        esac || { echo_log "$_op $_svc 失败"; _mso_rc=1; }
    done
    return "$_mso_rc"
}

# 等待 Core 按当前 config.yaml 启动控制 API。端口与 secret 均从 Core 配置读取。
mp_wait_core_ready() {
    _mwcr_timeout="${1:-30}"
    _mwcr_api=$(mp_core_api_url) || return 1
    _mwcr_secret=$(mp_core_value "" secret 2>/dev/null || :)
    _mwcr_start=$(date +%s)
    while [ "$(($(date +%s) - _mwcr_start))" -lt "$_mwcr_timeout" ]; do
        if [ -n "$_mwcr_secret" ]; then
            curl --silent --show-error --fail --max-time 2 --noproxy '*' \
                -H "Authorization: Bearer $_mwcr_secret" "$_mwcr_api/version" >/dev/null 2>&1 \
                && return 0
        else
            curl --silent --show-error --fail --max-time 2 --noproxy '*' \
                "$_mwcr_api/version" >/dev/null 2>&1 && return 0
        fi
        sleep 1
    done
    echo_log "Core API 在 ${_mwcr_timeout}s 内未就绪：$_mwcr_api"
    return 1
}

# 当前 OS 下 sh/etc/ 与 /etc/ 共用的相对路径清单；服务文件结构变了改这里一处
mp_etc_rels() {
    _mer_os=$(mp_detect_os) || return 1
    case "$_mer_os" in
        openwrt) echo "init.d/proxy_core init.d/agh hotplug.d/net/99-meta-route" ;;
        systemd) echo "systemd/system/proxy_core.service systemd/system/agh.service" ;;
    esac
}

# mp_set_etc_mode <path>
# systemd unit 是配置文件，不应带可执行位；OpenWrt init/hotplug 文件需要可执行。
mp_set_etc_mode() {
    case "$1" in
        *.service) chmod 0644 "$1" ;;
        *)         chmod 0755 "$1" ;;
    esac
}

# mp_sync_etc_files <never|always|if-exists>
# 统一完成路径占位替换、文件模式设置和可选的 /etc 同步。
mp_sync_etc_files() {
    _msef_mode="$1"
    case "$_msef_mode" in never|always|if-exists) ;; *) return 1 ;; esac
    _msef_os=$(mp_detect_os) || return 1
    _msef_rels=$(mp_etc_rels) || return 1
    _msef_changed=0; _msef_rc=0
    for _msef_rel in $_msef_rels; do
        _msef_src="$MP_INST_DIR/sh/etc/$_msef_rel"
        [ -f "$_msef_src" ] || { echo_log "$_msef_rel 不存在，跳过"; continue; }
        if ! sed -i "s|/etc/proxy|$MP_INST_DIR|g" "$_msef_src" \
           || ! mp_set_etc_mode "$_msef_src"; then
            echo_log "处理 $_msef_src 失败"
            _msef_rc=1
            continue
        fi
        case "$_msef_mode" in
            never) continue ;;
            if-exists) [ -e "/etc/$_msef_rel" ] || continue ;;
            always) mkdir -p "/etc/$(dirname "$_msef_rel")" \
                        || { _msef_rc=1; continue; } ;;
        esac
        if cp "$_msef_src" "/etc/$_msef_rel" \
           && mp_set_etc_mode "/etc/$_msef_rel"; then
            echo_log "同步 /etc/$_msef_rel"
            _msef_changed=1
        else
            echo_log "同步 /etc/$_msef_rel 失败"
            _msef_rc=1
        fi
    done
    if [ "$_msef_changed" -eq 1 ] && [ "$_msef_os" = systemd ]; then
        systemctl daemon-reload || _msef_rc=1
    fi
    return "$_msef_rc"
}

# mp_fetch_repo_sh <dst-sh-dir>
# 从 MP_REPO_RAW_URL 派生 owner/repo + 分支，拉 GitHub codeload tarball，
# 仅把 sh/ 子树覆盖到 <dst-sh-dir>。env.local.conf 不在 tarball 里所以不会被动。
# 故意不解压 core/ agh/ domain/——这些有渲染后状态或独立刷新流程。
mp_fetch_repo_sh() {
    _mfr_dst="$1"
    case "$MP_REPO_RAW_URL" in
        https://raw.githubusercontent.com/*)
            _mfr_path=${MP_REPO_RAW_URL#https://raw.githubusercontent.com/}
            ;;
        http://raw.githubusercontent.com/*)
            _mfr_path=${MP_REPO_RAW_URL#http://raw.githubusercontent.com/}
            ;;
        *)
            echo_log "update-scripts 仅支持 raw.githubusercontent.com 仓库根 URL"
            return 1
            ;;
    esac
    _mfr_owner=${_mfr_path%%/*}
    _mfr_rest=${_mfr_path#*/}
    _mfr_repo=${_mfr_rest%%/*}
    _mfr_tail=${_mfr_rest#*/}
    [ -n "$_mfr_owner" ] && [ -n "$_mfr_repo" ] \
        && [ "$_mfr_rest" != "$_mfr_repo" ] && [ -n "$_mfr_tail" ] \
        || { echo_log "MP_REPO_RAW_URL 缺少 owner/repo/branch"; return 1; }
    case "$_mfr_tail" in
        refs/heads/*) _mfr_branch=${_mfr_tail#refs/heads/} ;;
        *)            _mfr_branch=$_mfr_tail ;;
    esac
    [ -n "$_mfr_branch" ] || { echo_log "MP_REPO_RAW_URL 缺少分支"; return 1; }
    _mfr_url="https://codeload.github.com/$_mfr_owner/$_mfr_repo/tar.gz/refs/heads/$_mfr_branch"

    _mfr_tmp=$(mktemp -d) || return 1
    if ! download_file "$_mfr_url" "$_mfr_tmp/repo.tar.gz" true; then
        rm -rf "$_mfr_tmp"; return 1
    fi
    if ! tar -xzf "$_mfr_tmp/repo.tar.gz" -C "$_mfr_tmp" 2>/dev/null; then
        echo_log "tar 解压失败"; rm -rf "$_mfr_tmp"; return 1
    fi
    # tarball 应只有一个顶层目录，显式计数，避免 glob 拼成带空格的假路径。
    _mfr_src=; _mfr_src_count=0
    for _mfr_candidate in "$_mfr_tmp"/*/sh; do
        [ -d "$_mfr_candidate" ] || continue
        _mfr_src=$_mfr_candidate
        _mfr_src_count=$((_mfr_src_count + 1))
    done
    [ "$_mfr_src_count" -eq 1 ] \
        || { echo_log "tarball 结构异常：期望唯一 sh/"; rm -rf "$_mfr_tmp"; return 1; }

    mkdir -p "$_mfr_dst"
    _mfr_files="$_mfr_tmp/files.list"
    find "$_mfr_src" -type f -print > "$_mfr_files" \
        || { echo_log "枚举 tarball sh/ 失败"; rm -rf "$_mfr_tmp"; return 1; }
    _mfr_failed=0
    while IFS= read -r _mfr_file; do
        _mfr_rel=${_mfr_file#"$_mfr_src"/}
        _mfr_target="$_mfr_dst/$_mfr_rel"
        _mfr_target_dir=$(dirname "$_mfr_target")
        mkdir -p "$_mfr_target_dir" || { _mfr_failed=1; break; }
        _mfr_stage=$(mktemp "$_mfr_target_dir/.sync.XXXXXX") \
            || { _mfr_failed=1; break; }
        if ! cp -p "$_mfr_file" "$_mfr_stage" || ! mv "$_mfr_stage" "$_mfr_target"; then
            rm -f "$_mfr_stage"
            _mfr_failed=1
            break
        fi
    done < "$_mfr_files"
    if [ "$_mfr_failed" -ne 0 ]; then
        echo_log "原子同步 sh/ 失败"
        rm -rf "$_mfr_tmp"
        return 1
    fi
    chmod +x "$_mfr_dst"/*.sh 2>/dev/null || :
    rm -rf "$_mfr_tmp"
    return 0
}

# mp_fetch_core_providers [config]
# 预下载 proxy-providers / rule-providers 中 type=http 且显式配置 path 的文件。
# path 仅允许 Core home 内的安全相对路径；下载仍统一走 download_file 回退链。
mp_fetch_core_providers() {
    _mfp_config="${1:-$MP_CORE_DIR/config.yaml}"
    [ -f "$_mfp_config" ] || { echo_log "未找到 Core 配置：$_mfp_config"; return 1; }
    _mfp_list=$(mktemp) || return 1
    awk '
    function clean(v) {
        sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v)
        sub(/[[:space:]]+#.*/, "", v)
        if ((substr(v, 1, 1) == "\"" && substr(v, length(v), 1) == "\"") ||
            (substr(v, 1, 1) == "\047" && substr(v, length(v), 1) == "\047")) {
            v = substr(v, 2, length(v) - 2)
        }
        return v
    }
    function emit() {
        if (name != "" && type == "http") print section "\t" name "\t" url "\t" path
        name = ""; type = ""; url = ""; path = ""; field_indent = -1
    }
    BEGIN { section = ""; provider_indent = -1; field_indent = -1 }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    {
        match($0, /^[[:space:]]*/); indent = RLENGTH
        line = $0; sub(/^[[:space:]]+/, "", line)
    }
    indent == 0 && line ~ /^(proxy-providers|rule-providers):[[:space:]]*$/ {
        emit(); section = line; sub(/:.*/, "", section); provider_indent = -1; next
    }
    section != "" && indent == 0 { emit(); section = "" }
    section != "" {
        if (provider_indent < 0) provider_indent = indent
        if (indent == provider_indent && line ~ /:[[:space:]]*$/) {
            emit(); name = line; sub(/:[[:space:]]*$/, "", name); name = clean(name); next
        }
        if (name != "" && indent > provider_indent) {
            if (field_indent < 0) field_indent = indent
            if (indent == field_indent) {
                if (index(line, "type:") == 1) { type = clean(substr(line, 6)); next }
                if (index(line, "url:")  == 1) { url  = clean(substr(line, 5)); next }
                if (index(line, "path:") == 1) { path = clean(substr(line, 6)); next }
            }
        }
    }
    END { emit() }
    ' "$_mfp_config" > "$_mfp_list"

    _mfp_found=0; _mfp_failed=0
    _mfp_tab=$(printf '\t')
    while IFS="$_mfp_tab" read -r _mfp_kind _mfp_name _mfp_url _mfp_path; do
        [ -n "$_mfp_name" ] || continue
        _mfp_found=$((_mfp_found + 1))
        case "$_mfp_url" in
            http://*|https://*) ;;
            *) echo_log "$_mfp_kind/$_mfp_name 缺少有效 url"; _mfp_failed=1; continue ;;
        esac
        while [ "${_mfp_path#./}" != "$_mfp_path" ]; do _mfp_path=${_mfp_path#./}; done
        case "$_mfp_path" in
            ''|.|..|/*|../*|*/../*|*/..)
                echo_log "$_mfp_kind/$_mfp_name 缺少安全有效的 path"
                _mfp_failed=1; continue
                ;;
        esac
        _mfp_dst="$MP_CORE_DIR/$_mfp_path"
        mkdir -p "$(dirname "$_mfp_dst")"
        echo_log ">>> 预下载 $_mfp_kind/$_mfp_name"
        download_file "$_mfp_url" "$_mfp_dst" || _mfp_failed=1
    done < "$_mfp_list"
    rm -f "$_mfp_list"

    [ "$_mfp_found" -gt 0 ] || { echo_log "Core 配置中没有需要预下载的 HTTP provider"; return 0; }
    [ "$_mfp_failed" -eq 0 ] || return 1
    echo_log "Core providers 预下载完成：$_mfp_found 个"
}

# 根据当前 Core 代理端口同步已有 agh.yaml 的 http_proxy。
mp_sync_agh_http_proxy() {
    _msap_core_config="${1:-$MP_CORE_DIR/config.yaml}"
    _msap_agh_config="${2:-$MP_AGH_DIR/agh.yaml}"
    [ -f "$_msap_agh_config" ] || return 0
    _msap_proxy=$(mp_core_proxy_url "$_msap_core_config" agh) || return 1
    _msap_tmp=$(mktemp "$_msap_agh_config.tmp.XXXXXX") || return 1
    awk -v proxy="$_msap_proxy" '
        /^http_proxy:[[:space:]]*/ { print "http_proxy: \"" proxy "\""; found = 1; next }
        { print }
        END { if (!found) exit 1 }
    ' "$_msap_agh_config" > "$_msap_tmp" \
        && mv "$_msap_tmp" "$_msap_agh_config" \
        || { rm -f "$_msap_tmp"; return 1; }
}

# mp_fetch_agh_filters [agh.yaml]
# 从 AGH 配置顶层 filters / whitelist_filters 段提取 id + url，预下载到
# AGH 工作目录约定的 data/filters/<id>.txt。已有文件仅在下载成功后原子替换。
mp_fetch_agh_filters() {
    _maf_config="${1:-$MP_AGH_DIR/agh.yaml}"
    _maf_dir="$MP_AGH_DIR/data/filters"
    [ -f "$_maf_config" ] || { echo_log "未找到 AGH 配置：$_maf_config"; return 1; }

    _maf_list=$(mktemp) || return 1
    awk '
    function trim_value(v) {
        sub(/^[[:space:]]+/, "", v)
        sub(/[[:space:]]+$/, "", v)
        if ((substr(v, 1, 1) == "\"" && substr(v, length(v), 1) == "\"") ||
            (substr(v, 1, 1) == "\047" && substr(v, length(v), 1) == "\047")) {
            v = substr(v, 2, length(v) - 2)
        }
        return v
    }
    function emit() {
        if (item && id ~ /^[0-9]+$/ && url ~ /^https?:\/\//) print id " " url
        item = 0; id = ""; url = ""
    }
    /^(filters|whitelist_filters):[[:space:]]*$/ {
        emit(); section = 1; next
    }
    section && /^[^[:space:]]/ {
        emit(); section = 0
    }
    section && /^[[:space:]]*-[[:space:]]/ {
        emit(); item = 1
    }
    section && /^[[:space:]]*(id|-[[:space:]]+id):[[:space:]]*/ {
        line = $0; sub(/^[[:space:]]*(-[[:space:]]+)?id:[[:space:]]*/, "", line)
        id = trim_value(line)
    }
    section && /^[[:space:]]*(url|-[[:space:]]+url):[[:space:]]*/ {
        line = $0; sub(/^[[:space:]]*(-[[:space:]]+)?url:[[:space:]]*/, "", line)
        url = trim_value(line)
    }
    END { emit() }
    ' "$_maf_config" > "$_maf_list"

    mkdir -p "$_maf_dir"
    _maf_found=0; _maf_failed=0
    while IFS=' ' read -r _maf_id _maf_url; do
        [ -n "$_maf_id" ] && [ -n "$_maf_url" ] || continue
        _maf_found=$((_maf_found + 1))
        echo_log ">>> 预下载 AGH filter $_maf_id"
        if ! download_file "$_maf_url" "$_maf_dir/$_maf_id.txt"; then
            echo_log "AGH filter $_maf_id 下载失败"
            _maf_failed=1
        fi
    done < "$_maf_list"
    rm -f "$_maf_list"

    [ "$_maf_found" -gt 0 ] || { echo_log "AGH 配置中没有可下载的 filter"; return 0; }
    [ "$_maf_failed" -eq 0 ] || return 1
    echo_log "AGH filters 预下载完成：$_maf_found 个"
}

# mp_prepare_agh_config <dst> [core-config]
# 下载并渲染仓库 agh.yaml，以 Core 配置同步 http_proxy，并预下载其中的过滤器。
# 全部成功后才原子替换 dst；适用于安装时直接生成正式配置，以及更新时生成待切换配置。
mp_prepare_agh_config() {
    _mpac_dst="$1"
    _mpac_core_config="${2:-$MP_CORE_DIR/config.yaml}"
    [ -n "$_mpac_dst" ] || return 1
    [ -f "$_mpac_core_config" ] \
        || { echo_log "未找到 Core 配置：$_mpac_core_config"; return 1; }

    mkdir -p "$MP_AGH_DIR" || return 1
    _mpac_tpl=$(mktemp "$MP_AGH_DIR/.agh-template.XXXXXX") || return 1
    _mpac_rendered=$(mktemp "$MP_AGH_DIR/.agh-rendered.XXXXXX") \
        || { rm -f "$_mpac_tpl"; return 1; }

    if ! download_file "$MP_REPO_RAW_URL/agh/agh.yaml" "$_mpac_tpl"; then
        echo_log "下载 agh.yaml 失败"
        rm -f "$_mpac_tpl" "$_mpac_rendered"
        return 1
    fi
    if ! mp_render_template "$_mpac_tpl" "$_mpac_rendered"; then
        echo_log "渲染 agh.yaml 失败"
        rm -f "$_mpac_tpl" "$_mpac_rendered"
        return 1
    fi
    rm -f "$_mpac_tpl"

    if ! mp_sync_agh_http_proxy "$_mpac_core_config" "$_mpac_rendered"; then
        echo_log "无法从 Core 配置生成 AGH http_proxy"
        rm -f "$_mpac_rendered"
        return 1
    fi
    if ! mp_fetch_agh_filters "$_mpac_rendered"; then
        echo_log "AGH filter 预下载失败"
        rm -f "$_mpac_rendered"
        return 1
    fi
    if ! mv "$_mpac_rendered" "$_mpac_dst"; then
        echo_log "写入 AGH 配置失败：$_mpac_dst"
        rm -f "$_mpac_rendered"
        return 1
    fi
    echo_log "agh.yaml 已准备：$_mpac_dst"
}

# 模板渲染：用环境里同名 MP_* 变量替换文件中的 {MP_xxx} 占位符；原子替换
# mp_render_template <src> <dst>
mp_render_template() {
    _mrt_tmp=$(mktemp "$2.tmp.XXXXXX") || return 1
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
    }' "$1" > "$_mrt_tmp" && mv "$_mrt_tmp" "$2" \
        || { rm -f "$_mrt_tmp"; return 1; }
}

# 从缩进式 yaml 取顶层 map 下的子 key 列表
_yaml_extract_keys() {
    [ -f "$1" ] || return 1
    awk -v top="$2" '
    BEGIN { in_blk = 0; child_indent = -1 }
    $0 ~ "^" top ":[[:space:]]*$" { in_blk = 1; next }
    in_blk {
        if ($0 ~ /^[[:space:]]*$/) next
        if ($0 ~ /^[[:space:]]*#/) next
        match($0, /^[[:space:]]*/); indent = RLENGTH
        if (indent == 0) { in_blk = 0; next }
        if (child_indent < 0) child_indent = indent
        if (indent != child_indent) next
        line = $0; sub(/^[[:space:]]+/, "", line)
        if (match(line, /^[A-Za-z0-9_.-]+:/)) print substr(line, 1, RLENGTH-1)
    }
    ' "$1"
}
