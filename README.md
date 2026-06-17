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

需要先装好 mihomo 与 AdGuardHome；路径与默认不同时在 `env.local.conf` 用 `MP_CORE_BIN` / `MP_AGH_BIN` 覆盖。

inst.sh 第一个位置参数指定 sh 目录；省略时用 `$PWD`。`core` 和 `agh` 自动作为 sh 目录的兄弟目录派生（即 `dirname(sh)/core` 与 `dirname(sh)/agh`）。

### 一键安装

```sh
# 推荐：在新建目录里运行，sh/core/agh 自动落在该目录下
mkdir -p /opt/myproxy/sh && cd $_
wget -O- https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/inst.sh | sh
#  → 装到 /opt/myproxy/{sh,core,agh}

# 显式指定 sh 路径（兼容老的 /etc/proxy/ 布局）
wget -O- https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/inst.sh | sh -s -- /etc/proxy/sh
#  → 装到 /etc/proxy/{sh,core,agh}

# 装分支版本（开发调试）
MP_REPO_RAW_URL=https://raw.githubusercontent.com/AfxMsgBox/MyRule/refs/heads/<branch> \
    wget -O- "$MP_REPO_RAW_URL/sh/inst.sh" | sh -s -- /etc/proxy/sh
```

inst.sh 自动识别 OpenWrt / systemd 并分发对应服务文件，最后启用并启动服务。安装目录与仓库分支会写入 `env.local.conf`。

### env.local.conf

本机配置文件，**不入库**（`.gitignore` 已忽略），位置固定为 `$MP_SH_DIR/env.local.conf`。

**规则**：

- 纯 shell 语法，被 `env.conf` `source` 读取。每行 `KEY="value"`，值有空格 / 特殊字符必须加引号。
- 可覆盖 `env.conf` 里任意 `MP_*` 变量。
- 优先级（高 → 低）：**系统环境变量 > env.local.conf > env.conf 默认值**
  - 临时调试用 `MP_FOO=xxx sh script.sh` 即可压过 env.local.conf。
- `inst.sh` 安装结束时会自动写入两项：
  - `MP_SH_DIR` —— 实际安装路径（让 init.d / systemd 服务定位 env.local.conf）
  - `MP_REPO_RAW_URL` —— 当次安装使用的仓库 URL（默认 main，分支安装会写入分支 URL）
- 重复运行 inst.sh 时上述两项会被更新（不会重复追加）；用户加的其它行不动。

**必填项**（缺一不可，否则代理无法工作）：

| 变量 | 说明 |
|---|---|
| `MP_SUBSCRIBE_URL` | 节点订阅 URL（`core/config.yaml` 的 `{MP_SUBSCRIBE_URL}` 占位符引用） |

**条件必填**（与默认值不同时才填）：

| 变量 | 默认值 | 何时需要填 |
|---|---|---|
| `MP_CORE_BIN` | `$MP_CORE_DIR/mihomo` | mihomo 二进制不在 `core` 目录下 |
| `MP_AGH_BIN` | `/usr/bin/AdGuardHome` | AdGuardHome 不在系统默认路径 |
| `MP_LOCAL_DNS` | `"223.5.5.5 114.114.114.114"` | 想用别的上游；置空则读 `/etc/resolv.conf` |

**inst.sh 自动写入**（不要手动改）：

| 变量 | 说明 |
|---|---|
| `MP_SH_DIR` | 实际安装路径，init.d / systemd 服务靠它定位 env.local.conf |
| `MP_REPO_RAW_URL` | 当次安装使用的仓库 URL（含分支） |

**示例**（最小化，单机 + 默认路径）：

```sh
MP_SUBSCRIBE_URL="https://api.subcsub.com/sub?target=clash&url=<URL-encoded>"
# 下面两行由 inst.sh 自动写入：
MP_SH_DIR="/etc/proxy/sh"
MP_REPO_RAW_URL="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main"
```

可覆盖的完整变量清单见 `sh/env.conf`。

填好后刷新配置 + 重启服务：

```sh
sh $MP_SH_DIR/update-all-configs-restart-services.sh
```

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
