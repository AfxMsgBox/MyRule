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

`inst.sh` 第一个位置参数指定**安装根目录**；`sh/`、`core/`、`agh/` 都会落在它下面。省略时用 `$PWD`。服务文件副本（已替换路径占位）放在 `sh/etc/` 下，结构与仓库 `sh/etc/` 一致。

启动后会**交互式向导**让你填 6 项：仓库分支、节点订阅 URL、AGH 用户名、AGH 密码（bcrypt 哈希）、AGH 上游 DNS、是否立即启用自启动。重装时方括号显示当前值，回车保留。无 tty 时（cron）跳过向导，要求 `env.local.conf` 已具备必填项；自启动询问无 tty 时默认走"启用"分支。

最后一步**自启动询问**：
- **Y（默认）**：把 `sh/etc/` 下的服务文件复制到 `/etc/init.d`（OpenWrt）或 `/etc/systemd/system`（Debian），并 `enable + start`。后续 `update-scripts.sh` 也会同步覆盖这些 `/etc` 副本。
- **n**：不动 `/etc`，服务文件留在 `$MP_INST_DIR/sh/etc/`。`inst.sh` 结尾会打印对应的手动安装命令（也可以以后重跑 `inst.sh` 选 Y）。

随后按 `uname -m` 识别架构（amd64 / arm64 / armv5-7 / 386 / mips(le)(_softfloat) / mips64(le) / riscv64），从 GitHub Releases 下载最新版 mihomo 与 AdGuardHome 到 `core/` 与 `agh/`（**每次都覆盖**，不做版本比较；如需单独升级二进制见 `update-bin.sh`）。

### 一键安装

```sh
# 推荐：在新建目录里运行
mkdir -p /opt/myproxy && cd $_
wget -O- https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/inst.sh | sh
#  → 装到 /opt/myproxy/{sh,core,agh}

# 显式指定根目录
wget -O- https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/inst.sh | sh -s -- /etc/proxy
#  → 装到 /etc/proxy/{sh,core,agh}

# 装分支版本（开发调试）
MP_REPO_RAW_URL=https://raw.githubusercontent.com/AfxMsgBox/MyRule/refs/heads/claude/update-readme-overview-pU5D3 \
    wget -O- "$MP_REPO_RAW_URL/sh/inst.sh" | sh -s -- /etc/proxy
```

inst.sh 自动识别 OpenWrt / systemd 并分发对应服务文件，最后启用并启动服务。

### 生成 AGH 管理员密码

`MP_AGH_PASSWORD` 写入 `agh.yaml` 的 `password` 字段，AGH 要求 bcrypt 哈希（`$2a$/$2b$/$2y$` 开头）。任选一种生成：

```sh
htpasswd -bnBC 10 "" '明文' | cut -d: -f2     # apache2-utils
mkpasswd -m bcrypt-a '明文'                    # Debian: apt install whois
python3 -c "import bcrypt;print(bcrypt.hashpw(b'明文',bcrypt.gensalt(10)).decode())"
```

向导里粘贴生成的哈希即可。

### env.local.conf

本机配置文件，**不入库**（`.gitignore` 已忽略），位置固定为 `$MP_INST_DIR/sh/env.local.conf`。inst.sh 向导会按下表写入；想手动改也行。

**规则**：

- 纯 shell 语法，被 `env.conf` `source` 读取。每行 `KEY="value"`，值有空格 / 特殊字符必须加引号。
- 可覆盖 `env.conf` 里任意 `MP_*` 变量。
- 优先级（高 → 低）：**系统环境变量 > env.local.conf > env.conf 默认值**
  - 临时调试用 `MP_FOO=xxx sh script.sh` 即可压过 env.local.conf。
- 重复运行 inst.sh 时下表中各项被 upsert（已存在则替换，不存在则追加），用户加的其它行不动。

**inst.sh 向导询问 + 写入**：

| 变量 | 默认 | 必填 | 说明 |
|---|---|---|---|
| `MP_REPO_RAW_URL` | `.../main` | | 仓库 raw 根 URL；向导输入分支名自动拼成 `.../refs/heads/<branch>` |
| `MP_SUBSCRIBE_URL` | 空 | ✔ | 节点订阅 URL（`core/config.yaml` 的 `{MP_SUBSCRIBE_URL}` 引用） |
| `MP_AGH_USER_NAME` | 空 | ✔ | AGH Web UI 用户名 |
| `MP_AGH_PASSWORD` | 空 | ✔ | AGH Web UI 密码（**bcrypt 哈希**，生成方法见上节） |
| `MP_LOCAL_DNS` | `223.5.5.5 119.29.29.29` | | AGH 上游 DNS（空格分隔多个；置空读 `/etc/resolv.conf`） |
| `MP_INST_DIR` | 由 inst.sh 自动写入 | | 安装根目录，init.d / systemd 服务靠它定位 env.local.conf |

**示例**（最小化，单机 + 默认路径）：

```sh
MP_INST_DIR="/etc/proxy"
MP_REPO_RAW_URL="https://raw.githubusercontent.com/AfxMsgBox/MyRule/main"
MP_SUBSCRIBE_URL="https://api.subcsub.com/sub?target=clash&url=<URL-encoded>"
MP_AGH_USER_NAME="admin"
MP_AGH_PASSWORD="$2a$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy"
MP_LOCAL_DNS="223.5.5.5 119.29.29.29"
```

可覆盖的完整变量清单见 `sh/env.conf`。

填好后刷新配置 + 重启服务：

```sh
sh $MP_INST_DIR/sh/update-all-configs-restart-services.sh
```

---

## 日常运维

下表用 `/etc/proxy` 作示例路径；装在别处把 `/etc/proxy` 换成你的 `$MP_INST_DIR`。

**核心设计**：刷新分**三种**，互不交叉——脚本只更新脚本，配置只更新配置，二进制只更新二进制。除了 `update-scripts.sh`，**其它脚本都不会动脚本自身**，行为可控。

### ① 刷新脚本（唯一入口）

| 操作 | 命令 |
|---|---|
| 刷新所有脚本（含 env.conf / common.sh / sh/etc/* / 自身） | `sh /etc/proxy/sh/update-scripts.sh` |

`update-scripts.sh` 会重新下载 `sh/*.sh` 与 `sh/etc/*`；当初 inst 选了自启动（`/etc` 下已有副本），还会同步覆盖到 `/etc` 并 `systemctl daemon-reload`（systemd 时）。

### ② 刷新配置

| 操作 | 命令 |
|---|---|
| 全部配置（AGH dns.conf + core config.yaml + 订阅规则集 PUT） | `sh /etc/proxy/sh/update-all-configs.sh` |
| 全部配置 + 重启 agh / proxy_core | `sh /etc/proxy/sh/update-all-configs-restart-services.sh` |
| 仅 AGH dns.conf | `sh /etc/proxy/sh/update-agh-config.sh` |
| 仅 core config.yaml | `sh /etc/proxy/sh/update-core-config.sh` |
| 仅订阅与规则集（PUT mihomo providers） | `sh /etc/proxy/sh/update-proxy-rule.sh` |

新增 / 修改分流规则：编辑 `domain/*.txt` push 到 `main`，下次 cron 触发或手动 `update-agh-config.sh` / `update-all-configs.sh` 即可同步。

### ③ 刷新二进制

| 操作 | 命令 |
|---|---|
| 升级 mihomo + AdGuardHome | `sh /etc/proxy/sh/update-bin.sh` |
| 升级后重启服务 | `sh /etc/proxy/sh/update-bin.sh && systemctl restart proxy_core agh` |

### 其它

| 操作 | 命令 |
|---|---|
| 看日志 (OpenWrt) | `logread -e MyProxy -f` |
| 看日志 (Debian) | `journalctl -t MyProxy -f` |
| 清 fake-ip 缓存 | `curl -X POST $MP_CORE_API/cache/fakeip/flush` |

### 推荐 cron

```cron
*/5 * * * *  sh /etc/proxy/sh/keeplive.sh
0   3 * * 0  sh /etc/proxy/sh/update-scripts.sh
0   4 * * *  sh /etc/proxy/sh/update-all-configs-restart-services.sh
0   5 1 * *  sh /etc/proxy/sh/update-bin.sh && systemctl restart proxy_core agh
```

每周一次刷脚本、每天一次刷配置 + 重启、每月一次升级二进制 + 重启。频率按需调整。

---

## 仓库结构

```
sh/             脚本与模板
  inst.sh                      首次安装
  update-scripts.sh            刷新所有脚本（含 env.conf / common.sh / sh/etc/* / 自身）
  update-bin.sh                刷新 mihomo / AdGuardHome 二进制
  update-all-configs.sh        刷新所有配置
  update-all-configs-restart-services.sh  上面 + 重启服务
  update-agh-config.sh         仅 AGH dns.conf
  update-core-config.sh        仅 core config.yaml
  update-proxy-rule.sh         仅订阅与规则集（PUT mihomo providers）
  keeplive.sh                  保活
  setup-fake-ip-route.sh       fake-ip 路由修正（hotplug / ExecStartPost）
  env.conf / common.sh         全局变量 / 公共函数
  etc/init.d/                  OpenWrt procd 服务（原始模板）
  etc/hotplug.d/net/           OpenWrt hotplug
  etc/systemd/system/          Debian systemd unit（原始模板）
core/config.yaml               Mihomo 主配置模板（含 {MP_*} 占位符）
agh/agh.yaml                   AdGuardHome 配置模板（含 {MP_*} 占位符）
agh/myupstream.txt             AGH 自定义上游
domain/                        分流域名清单（Clash payload 格式）
```

安装后在 `$MP_INST_DIR/sh/etc/` 下会有一份**已替换路径占位**的服务文件副本，结构与仓库 `sh/etc/` 一致。`update-scripts.sh` 维护这份副本，并在用户当初选了自启动（`/etc` 下已存在）时同步覆盖。

各文件顶部都有简短说明，详细行为见脚本内注释。
