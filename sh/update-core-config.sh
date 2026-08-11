#!/bin/sh
# 拉取 core/config.yaml 模板，把 {MP_*} 占位符按当前环境替换后原子写入。
# 可选参数指定目标文件；省略时更新正式 config.yaml。
. "$(dirname "$(readlink -f "$0")")/common.sh"

echo_log "更新代理内核 config.yaml"
mkdir -p "$MP_CORE_DIR"
target_config="${1:-$MP_CORE_DIR/config.yaml}"

tpl=$(mktemp)
download_file "$MP_REPO_RAW_URL/core/config.yaml" "$tpl" \
    || { echo_log "下载 config.yaml 失败"; rm -f "$tpl"; exit 1; }

staged=$(mktemp "$MP_CORE_DIR/config.yaml.tmp.XXXXXX")
mp_render_template "$tpl" "$staged" \
    || { echo_log "渲染 config.yaml 失败"; rm -f "$tpl" "$staged"; exit 1; }
rm -f "$tpl"

# Core 配置是外围脚本的唯一运行基础，替换前先检查所有必需派生值。
mp_core_proxy_url "$staged" >/dev/null \
    && mp_core_api_url "$staged" >/dev/null \
    && mp_core_dns_endpoint "$staged" >/dev/null \
    && mp_core_fake_ip_cidr "$staged" >/dev/null \
    && mp_core_external_ui_path "$staged" >/dev/null \
    && [ -n "$(mp_core_value tun device "$staged" 2>/dev/null || :)" ] \
    || { echo_log "Core 配置缺少有效的代理/API/DNS/UI/TUN/fake-ip 字段"; rm -f "$staged"; exit 1; }

# 首次安装用外部代理；日常更新用当前旧 Core 代理。全部 provider 成功后才写目标文件。
mp_fetch_core_providers "$staged" \
    || { echo_log "Core provider 预下载失败"; rm -f "$staged"; exit 1; }

# AGH 配置由整批更新流程根据这份新 Core 配置另行生成，避免修改运行中
# 可能被 AdGuardHome 回写的 agh.yaml。
mv "$staged" "$target_config" \
    || { echo_log "写入 Core config.yaml 失败"; rm -f "$staged"; exit 1; }
echo_log "config.yaml 已生成：$target_config"
