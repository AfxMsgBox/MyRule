# MyRule

为 **OpenWrt** 与 **Debian/Ubuntu** 双平台部署的 **AdGuardHome + Mihomo** 透明代理与分流方案。

- DNS 入口（AdGuardHome）按域名决定走直连或代理
- 代理内核（Mihomo / Clash 兼容）用 fake-ip + TUN 接管被代理流量
- 所有配置、脚本、规则统一从 GitHub 同步，cron 周期自动更新

---

## 架构

```
客户端 → AdGuardHome(:53) ─┬─ 直连域名：返回真实 IP
                          └─ 代理域名：返回 fake-ip → 路由到 TUN → Mihomo → 出口节点
```

分流由 DNS 完成（AGH 看域名决定），代理内核只管"被分流到 TUN 的流量走哪个节点"。规则单点维护在仓库的 `domain/*.txt`，所有设备 cron 同步。

---

## 安装

需要先按默认路径装好二进制：
- `mihomo` → `/etc/proxy/core/mihomo`
- `AdGuardHome` → `/usr/bin/AdGuardHome`

路径不同时在 `env.local.conf` 用 `MP_CORE_BIN` / `MP_AGH_BIN` 覆盖。

### 一键安装

```sh
# 装到默认目录 /etc/proxy/sh
wget -O- https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/inst.sh | sh

# 装到自定义目录
wget -O- https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/inst.sh | sh -s -- /opt/myproxy/sh

# 装分支版本（开发调试）
MP_REPO_RAW_URL=https://raw.githubusercontent.com/AfxMsgBox/MyRule/refs/heads/<branch> \
    wget -O- "$MP_REPO_RAW_URL/sh/inst.sh" | sh
```

inst.sh 自动识别 OpenWrt / systemd 并分发对应服务文件，最后启用并启动服务。安装目录与仓库分支会写入 `env.local.conf`。

### 填敏感参数

`/etc/proxy/sh/env.local.conf` 是本地配置（不入库），填订阅 URL 等：

```sh
MP_SUBSCRIBE_URL="https://api.subcsub.com/sub?target=clash&url=<URL-encoded>"
MP_SSHSOS_USER="..."
MP_SSHSOS_PASSWORD="..."
MP_SSHSOS_SERVER="..."
```

填好后刷新配置 + 重启服务：

```sh
sh /etc/proxy/sh/update-all-configs-restart-services.sh
```

可覆盖的所有 `MP_*` 变量见 `sh/env.conf`。优先级：**系统环境变量 > env.local.conf > env.conf 默认值**。

---

## 日常运维

| 操作 | 命令 |
|---|---|
| 全量刷新 + 重启 | `sh /etc/proxy/sh/update-all-configs-restart-services.sh` |
| 仅刷新规则不重启 | `sh /etc/proxy/sh/update-all-configs.sh` |
| 仅刷新订阅与规则集 | `sh /etc/proxy/sh/update-proxy-rule.sh` |
| 跳过自更新 | 任一脚本加 `--autoupdate=false` |
| 看日志 (OpenWrt) | `logread -e MyProxy -f` |
| 看日志 (Debian) | `journalctl -t MyProxy -f` |
| 清 fake-ip 缓存 | `curl -X POST $MP_CORE_API/cache/fakeip/flush` |

新增 / 修改分流规则：直接编辑 `domain/*.txt` push 到 `main`，下次 cron 触发或手动 `update-all-configs.sh` 即可同步。

### 推荐 cron

```cron
*/5 * * * * sh /etc/proxy/sh/keeplive.sh
0   3 * * * sh /etc/proxy/sh/update-proxy-rule.sh
0   4 * * * sh /etc/proxy/sh/update-all-configs-restart-services.sh
```

---

## 仓库结构

```
sh/             脚本（env.conf / common.sh / inst.sh / update-*.sh / keeplive.sh ...）
  etc/init.d/                  OpenWrt procd 服务
  etc/hotplug.d/net/           OpenWrt hotplug
  etc/systemd/system/          Debian systemd unit
core/config.yaml               Mihomo 主配置模板（含 {MP_*} 占位符）
agh/                           AGH 自定义上游
domain/                        分流域名清单（Clash payload 格式）
```

各文件顶部都有简短说明，详细行为见脚本内注释。
