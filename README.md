# MyRule

面向 **OpenWrt 路由器**与 **Debian / Ubuntu 服务器**两类目标的一套 **AdGuardHome + Mihomo**（Mihomo 兼容 Clash 的命令行与配置 schema）透明代理与分流方案。仓库内集中维护：

- 一组**可自我更新**的 shell 脚本：每次执行先从 GitHub 拉到最新版本再继续运行；
- 代理内核（Mihomo）的主配置模板与本地占位符注入机制；
- AdGuardHome 用到的自定义上游 / 过滤条目；
- 在 AGH 与代理内核之间共享的分流域名清单；
- OpenWrt 的 `procd` 服务文件与 `hotplug` 路由处理；
- Debian/Ubuntu 的 `systemd` 服务文件（与 OpenWrt 版本共用一份配置 / 一份脚本，安装时按系统自动分发）。

部署一次后，新增 / 修改规则只需 push 到 `main` 分支；下一次计划任务触发时设备会自动同步并重载相关服务。

> 仓库内部把"Mihomo / Clash Meta / sing-box（Clash 协议兼容版）"这一类内核统称为 **core**：相关目录、服务名、变量名都用通用词命名（`core/`、`proxy_core`、`CORE_BIN`）。要换内核时只改 `sh/env.conf` 中的 `CORE_BIN`，无须再改文件名。

---

## 目录

- [整体架构](#整体架构)
- [仓库目录结构](#仓库目录结构)
- [文件逐一说明](#文件逐一说明)
- [安装与部署](#安装与部署)
  - [OpenWrt](#openwrt)
  - [Debian / Ubuntu](#debian--ubuntu)
- [从旧版（meta/ + clash_meta）迁移](#从旧版-meta--clash_meta-迁移)
- [日常运维](#日常运维)
- [关键端口与目录约定](#关键端口与目录约定)
- [设计要点](#设计要点)

---

## 整体架构

### 数据面：DNS → fake-ip → TUN

```
┌──────────────┐    53/udp    ┌──────────────────┐
│  局域网客户端 │ ───────────▶ │   AdGuardHome    │
└──────────────┘               │ (/etc/proxy/agh) │
       ▲                       └────────┬─────────┘
       │ 直连域名 / 国内域名             │ 命中分流列表的域名
       │ 直接应答真实 IP                 ▼
       │                       127.0.0.1:${CORE_DNS_PORT}（代理内核内置 DNS）
       │                                │ 返回 fake-ip
       │                                ▼
       │                       ${FAKE_IP_CIDR}（默认 172.16.0.0/12）
       │                                │ 客户端访问 fake-ip
       │                                ▼
       │                       OpenWrt 路由表
       │                                │ hotplug 把 ${FAKE_IP_CIDR} 指向 utun
       │                                ▼
       │                       Mihomo (TUN: utun)
       │                                │ 按 rules / proxy-groups 选择出口
       │                                ▼
       └──────────────── HongKong / TaiWan / Singapore / USA / sshSOS
```

要点：

1. AdGuardHome 是唯一 DNS 入口，根据 `dns.conf`（由 `update-agh-config.sh` 生成）决定域名是直接解析还是把请求改写成 `[/domain/]127.0.0.1:${CORE_DNS_PORT}` 转发到代理内核。
2. 代理内核在 `:253` 提供 fake-ip。
3. fake-ip 网段的路由由 `99-meta-route` 在 TUN 接口 `add` 事件时挂上去（`auto-route: false`）。
4. 进入 TUN 后，Clash 规则只剩两条：`RULE-SET,rule_gpt,gptProxy` 与 `MATCH,defaultProxy`；其余分流逻辑全部由 AGH 在 DNS 层完成。
5. 节点订阅按地区拆分（HongKong / TaiWan / Singapore / USA），每个地区做 `url-test` 健康检查，`defaultProxy` 与 `gptProxy` 只是不同优先级的手选策略组。

### 控制面：自更新脚本与配置注入

```
GitHub: AfxMsgBox/MyRule (main)
        │
        │ wget inst.sh | sh                  （首次安装）
        ▼
inst.sh ─▶ download-all-scripts.sh ─▶ 把脚本/服务/hotplug 全部下到本地
                                     ├──▶ /etc/init.d/{agh, proxy_core}
                                     ├──▶ /etc/hotplug.d/net/99-meta-route
                                     └──▶ /etc/proxy/sh/{env.conf, common.sh, *.sh}
        │
        │ cron 周期触发
        ▼
update-all-configs(-restart-services).sh
        │
        ├─ source common.sh                 ── 提供下载 / 替换占位符 / 日志 / 锁 / yaml 提取
        │      └─ 每个脚本启动时会先把自己升级到最新再 exec 重启
        │
        ├─ _run_step "更新 AGH dns.conf"    update-agh-config.sh
        ├─ _run_step "更新代理内核 yaml"     update-core-config.sh
        └─ _run_step "刷新订阅与规则集"      update-proxy-rule.sh
        │
        └─ 任一步失败 → 不重启服务（保留旧配置在线）
```

要点：

- **脚本自更新**：所有 `update-*.sh` 顶部都设置 `URL_SCRIPT` 指向自己的 GitHub raw URL，`source common.sh` 会用 `download_file` 把当前脚本替换到最新版后 `exec sh "$0" "$@" --noupdate`，**保留**原始命令行参数。
- **占位符 + local.conf**：仓库里只放可公开的模板（含 `{SUBSCRIBE_URL}`、`{sshSOS_*}` 等）；`local.conf` 放 `key=value` 形式的敏感值，**不进仓库**。`common.sh:replace_strings_from_config` 用 `awk` 严格按第一个 `=` 切分键值，避免正则注入和 `=` 出现在 value 中导致的漂移。
- **稳健下载**：`download_file` 默认走本地 HTTP 代理；若代理失败自动**降级直连**重试一次。临时文件用 `mktemp`，写入后做大小校验再原子替换目标。
- **集中配置**：所有硬编码的端口 / 路径 / URL 收敛到 `sh/env.conf`，被 `common.sh` 与各 `init.d` / `hotplug` 脚本共同 `source`。本地覆盖放 `sh/env.local.conf`（`.gitignore` 已忽略）。
- **失败不重启**：`update-all-configs.sh` 会汇总每一步的 exit code；只有全部成功时 `update-all-configs-restart-services.sh` 才执行 `service agh restart && service proxy_core restart`。
- **yaml 校验 / 配置回滚**：`update-core-config.sh` 替换占位符后做粗略校验（必含 `proxies:`、`proxy-providers:`、`rules:`，且不能残留 `{占位符}`），不通过就**保留旧 `config.yaml`**，不会把坏配置投入运行。
- **provider 自动发现**：`update-proxy-rule.sh` 通过 `_yaml_extract_keys` 从 `core/config.yaml` 读出所有 `proxy-providers` 与 `rule-providers` 的名字逐个 PUT 刷新——增减 provider 不再需要同步改脚本。
- **并发锁**：`update-all-configs.sh` 用 `flock`（`common.sh:_acquire_lock`）防止 cron 与手动同时跑导致互踩。

---

## 仓库目录结构

```
.
├── README.md
├── .gitignore
├── sh/
│   ├── env.conf                                 # 共享环境（端口/路径/URL/日志 tag）
│   ├── inst.sh                                  # 一键安装入口
│   ├── download-all-scripts.sh                  # 把仓库脚本与服务文件下到本地
│   ├── common.sh                                # 公共函数库（下载/替换/锁/日志/yaml/自更新）
│   ├── update-all-configs.sh                    # 顶层编排：依次刷新四类配置
│   ├── update-all-configs-restart-services.sh   # 全量更新成功后重启服务
│   ├── update-agh-config.sh                     # 生成 AGH 的 dns.conf
│   ├── update-core-config.sh                    # 生成代理内核 config.yaml（含粗略校验）
│   ├── update-proxy-rule.sh                     # provider 自动发现 + REST PUT 刷新
│   ├── keeplive.sh                              # 周期保活（缓解长连 idle 断流）
│   ├── setup-fake-ip-route.sh                   # 修正 mihomo TUN 路由 /30 bug（OpenWrt/Debian 通用）
│   └── etc/
│       ├── init.d/agh                           # OpenWrt：AdGuardHome 的 procd 服务
│       ├── init.d/proxy_core                    # OpenWrt：代理内核的 procd 服务（CORE_BIN 决定二进制）
│       ├── hotplug.d/net/99-meta-route          # OpenWrt：TUN 接口上线时调用 setup-fake-ip-route.sh
│       └── systemd/system/
│           ├── proxy_core.service               # Debian：代理内核的 systemd 服务（含 ExecStartPost 修路由）
│           └── agh.service                      # Debian：AdGuardHome 的 systemd 服务
├── agh/
│   ├── myupstream.txt                           # 自定义上游 DNS（域名→指定 DNS）
│   └── myfilter.txt                             # 自定义过滤 / hosts 条目
├── core/
│   ├── config.yaml                              # 代理内核主配置模板（含 {占位符}）
│   └── local.conf                               # 本地敏感参数示例（key=value）
└── domain/
    ├── myproxylist.txt                          # 常用代理域名（payload 列表）
    └── gpt.txt                                  # AI / Google 等专用分流域名
```

---

## 文件逐一说明

### sh/env.conf（新增）

被 `common.sh`、`init.d/proxy_core`、`99-meta-route` 共同 `source`。集中管理：

| 变量 | 默认值 | 用途 |
| --- | --- | --- |
| `PROXY_HTTP` | `http://127.0.0.1:7890` | 下载与保活走的本地 HTTP 代理 |
| `CORE_API` | `http://127.0.0.1:3721` | 代理内核外部控制器 |
| `CORE_DNS_PORT` | `253` | 内核内置 DNS 端口（fake-ip 出口） |
| `FAKE_IP_CIDR` | `172.16.0.0/12` | fake-ip 网段，hotplug 路由依据 |
| `CORE_DIR` / `CORE_BIN` | `/etc/proxy/core` / `$CORE_DIR/mihomo` | 内核工作目录与可执行文件 |
| `AGH_DIR` | `/etc/proxy/agh` | AdGuardHome 工作目录 |
| `TUN_IFACES` | `utun Meta` | 触发 hotplug 路由挂载的接口名 |
| `REPO_RAW_URL` | `https://raw.githubusercontent.com/AfxMsgBox/MyRule/main` | 仓库 raw 根 URL |
| `EXCLUDE_TLDS` | `bj` | 写入 `dns.conf` 时排除的伪 TLD |
| `LOG_TAG` | `MyProxy` | `logger -t` 用的统一 tag（`logread -e MyProxy` / `journalctl -t MyProxy`） |

末尾会尝试 source `sh/env.local.conf`（被 `.gitignore` 忽略）做本地覆盖。

### sh/common.sh

公共函数库。除继承原有 `download_file` / `replace_strings_from_config` / `echo_log` 之外，新增：

- `_run_step <label> <cmd…>`：包一段子任务，统一日志开头/结尾，返回子命令 exit。
- `_acquire_lock [path]`：基于 `flock` 的并发锁；若系统没有 flock 则降级为 noop。
- `_yaml_extract_keys <file> <top>`：从缩进式 yaml 取顶层 map 下的子 key 列表，给 `update-proxy-rule.sh` 自动发现 provider。

修复要点：

- `download_file` 用 `case` 严格判断 `use_proxy`，传 `0/false/no` 时不再误启用代理；代理失败时自动直连重试；临时文件改用 `mktemp` 避免并发互踩。
- `echo_log` 通过 `logger -t "$LOG_TAG"` 写日志，方便 `logread -e MyProxy`（OpenWrt）/ `journalctl -t MyProxy`（Debian）过滤。
- 自更新段透传原始命令行参数：`exec sh "$PATH_SCRIPT" "$@" --noupdate`。
- 所有变量加引号，避免空格 / 特殊字符破坏。

### sh/inst.sh / sh/download-all-scripts.sh

`inst.sh` 一行 `wget | sh` 的入口；`download-all-scripts.sh` 自动识别系统：

- 检测到 OpenWrt（`/etc/openwrt_release` 或 `/etc/os-release` 含 `ID=openwrt`）→ 装 `init.d/{agh,proxy_core}` 与 `hotplug.d/net/99-meta-route`；
- 检测到 systemd（`systemctl` + `/etc/systemd/system`）→ 装 `proxy_core.service` 与 `agh.service`，并执行 `systemctl daemon-reload`；
- 都识别不出 → 报错并提示通过 `OS_TYPE=openwrt|systemd sh download-all-scripts.sh` 强制指定。

公共 `sh/*.sh` 两类系统都会装。之所以仍然用 `wget` 而不是 `common.sh` 的 `download_file`：首次安装时 `common.sh` 自身也还没就位，必须用 BusyBox / GNU `wget` 引导。

### sh/update-all-configs.sh / sh/update-all-configs-restart-services.sh

`update-all-configs.sh` 是顶层编排器，按 `_run_step` 依次跑 agh / core / proxy-rule 三步，记录每一步 exit code，最终 exit 反映"是否全部成功"。

`update-all-configs-restart-services.sh` 仅在 `update-all-configs.sh` 整体成功时才 `service agh restart && service proxy_core restart`——避免坏配置被加载。

### sh/update-agh-config.sh

生成 `${AGH_DIR}/dns.conf`：

1. 顶部写时间戳；
2. 默认上游：优先 `local.dns.conf`，否则 `ip route` 取系统默认网关；
3. 拉取并合并 `agh/myupstream.txt` / `domain/myproxylist.txt` / `domain/gpt.txt` / Loyalsoldier 的 `tld-not-cn.txt` 与 `gfw.txt`；
4. 用 `sed` 把 Clash payload `- '+.example.com'` 转成 AGH 转发规则 `[/example.com/]127.0.0.1:${CORE_DNS_PORT}`；
5. 按 `EXCLUDE_TLDS` 一次性过滤伪 TLD（默认 `bj`，可在 `env.conf` 覆盖）。

每段下载用 `_run_step` 包一层，单一来源失败时记录但继续，整体策略与原版保持一致。

### sh/update-core-config.sh

下载最新 `core/config.yaml` 模板 → `replace_strings_from_config` 用 `core/local.conf` 替换占位符 → 校验：

- 必须含 `proxies:`、`proxy-providers:`、`rules:` 三个顶层段；
- 不能残留 `{占位符}`（残留意味着 `local.conf` 缺键）。

校验通过才把旧 `config.yaml` 移成 `.bak` 并替换；不通过则保留旧配置不动，并把残留的占位符行打印出来便于排查。

### sh/update-proxy-rule.sh

```
GET  ${CORE_API}/providers/proxies/<each proxy-provider>   ── PUT 触发刷新
GET  ${CORE_API}/providers/rules/<each rule-provider>      ── PUT 触发刷新
```

provider 名称由 `_yaml_extract_keys` 从当前 `config.yaml` 自动列出。每次 PUT 加 `--max-time 30`、根据 HTTP 状态码（204/200）判断是否成功，并 `sleep 2` 间隔避免对源站短时间高并发。

### sh/keeplive.sh

通过 `${PROXY_HTTP}` 周期 `curl -I` Google 与 ChatGPT，让节点保持长连接活跃。加了 `--max-time 5` 避免堵塞。

### sh/etc/init.d/agh （OpenWrt）

procd 服务，启动 `/usr/bin/AdGuardHome`：

- 工作目录 `/etc/proxy/agh`，主配置 `agh.yaml`；
- `procd_set_param respawn 3600 5 5` 崩溃自愈；
- `stop_service` 留空让 procd 默认 SIGTERM 收尾，**不再**用 `killall AdGuardHome`。

### sh/etc/init.d/proxy_core （OpenWrt）

procd 服务，启动 `${CORE_BIN}`（默认 `/etc/proxy/core/mihomo`）：

- 二进制路径完全由 `env.conf` 中的 `CORE_BIN` 决定，未来换 sing-box 改一处即可，init.d 文件不动；
- 启动前检查 `CORE_BIN` 必须存在且可执行，否则记录错误退出；
- 同样有 respawn 阈值；
- 删除了原有 "use clash / use meta" 兜底逻辑——内核统一为 mihomo 协议。

### sh/etc/hotplug.d/net/99-meta-route （OpenWrt）

TUN 接口 `add` 事件触发器，仅一行 `exec /etc/proxy/sh/setup-fake-ip-route.sh`，把真正的修路由逻辑交给共享脚本。原因见下一节。

### sh/setup-fake-ip-route.sh （OpenWrt + Debian 共用）

修复 **mihomo 的一个 TUN 路由 bug**：不论 `core/config.yaml` 中 `fake-ip-range` 写多少，mihomo 在 TUN 上线时总是把路由加成 `<网段起始>/30`（只覆盖 4 个 IP，余下整个 fake-ip 段无法被 TUN 接管）。

时序坑点：systemd 的 `ExecStartPost` 在 mihomo 进程刚 fork 后就触发，**TUN 尚未创建、/30 错路由尚未加上**——这时 `ip route del /30` 是 no-op，再 `ip route replace /12` 之后 mihomo 又会把 /30 覆盖回来，问题没解。OpenWrt hotplug 没这个问题，因为 hotplug 是接口完全配置好之后才 fire。

所以脚本流程是：

1. 找到 `${TUN_IFACES}` 中真正存在的接口（最多等 10 秒）；
2. **等 mihomo 把 `/30` 错路由真的加上来**（最多等 15 秒；hotplug 场景通常立刻命中）；
3. `ip route del <base>/30` + `ip route replace ${FAKE_IP_CIDR} dev <iface>`；
4. 睡 3 秒做二次校验，如果 mihomo 又抢回 `/30`（初始连接稳定前偶发）再修一次；
5. 通过 `logger -t ${LOG_TAG}` 留痕。

最坏情况 ~28s（系统启动期才会跑满），通常 1–3s 完成。OpenWrt 由 hotplug 触发，Debian 由 `proxy_core.service` 的 `ExecStartPost` 触发，同一段实现共用。

### sh/etc/systemd/system/proxy_core.service / agh.service （Debian / Ubuntu）

systemd 单元文件。要点：

- `ExecStart=/bin/sh -c '. /etc/proxy/sh/env.conf && exec "$CORE_BIN" -d "$CORE_DIR"'`：用 `sh` 引导以 `source` env.conf（systemd 的 `EnvironmentFile` 不能解析 `${VAR:-default}` 形式）；
- `proxy_core.service` 的 `ExecStartPost` 调用 `setup-fake-ip-route.sh`，等 TUN 出现后修正路由；
- `[Unit] StartLimitIntervalSec=3600 StartLimitBurst=5 + [Service] Restart=on-failure` 与 OpenWrt procd `respawn 3600 5 5` 等价；
- `AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW` 让进程在非 root 下也能管 TUN 与监听 53/853；
- 日志 `SyslogIdentifier=MyProxy`，`journalctl -t MyProxy -f` 即可统一观察。

### core/config.yaml

Mihomo 主配置模板，关键字段（占位符列入 `core/local.conf`）：

- 端口：`mixed-port: 7890`、`tproxy-port: 7893`、`external-controller: :3721`；
- 长连接：`keep-alive-idle: 1800`、`keep-alive-interval: 60`、`disable-keep-alive: true`，配合 `keeplive.sh`；
- TUN：`device: utun`、`stack: mixed`、`auto-route: false`，路由完全由 hotplug 管理；
- DNS：`enhanced-mode: fake-ip`、`listen: :253`、`fake-ip-range: 172.16.0.1/12`，国内 `nameserver` 走阿里/114，`fallback` 走 8.8.8.8；
- proxies：内置一个 `sshSOS` 节点；
- proxy-providers：HongKong / TaiWan / Singapore / USA 四个 HTTP 订阅；
- proxy-groups：四个 `url-test` + `defaultProxy` / `gptProxy` 两个手选；
- rule-providers：`rule_gpt` 远程拉取本仓库 `domain/gpt.txt`；
- rules：仅两条 —— `RULE-SET,rule_gpt,gptProxy` 与 `MATCH,defaultProxy`。

### core/local.conf（示例）

```
SUBSCRIBE_URL=https://api.subcsub.com/sub?target=clash&url=
sshSOS_password=pass
sshSOS_user=user
sshSOS_server=8.8.8.8
sshSOS_port=22
```

### agh/myupstream.txt

少量域名走指定 DNS 的自定义上游，原样追加到 `dns.conf`。

### agh/myfilter.txt

本地 hosts/过滤示例，留作运维按需引入 AGH 主配置（脚本目前未自动引用）。

### domain/myproxylist.txt / domain/gpt.txt

Clash payload YAML 域名清单。**修复**：

- `myproxylist.txt:4` 之前写的是 Unicode 弯引号 `‘`，会导致整份 payload 解析异常；已改为 ASCII `'`；
- `myproxylist.txt` 中 `+.docker.com` / `+.docker.io` 重复条目已删除；
- `gpt.txt` 中 `+.google.cn` 重复条目已删除。

---

## 安装与部署

工作根目录约定 `/etc/proxy/`，两个目标系统通用：

```
/etc/proxy/sh/      所有脚本与 env.conf
/etc/proxy/core/    mihomo 二进制与 config.yaml / local.conf
/etc/proxy/agh/     AdGuardHome 工作目录
```

### OpenWrt

#### 1. 安装内核与 AdGuardHome

- 把 AdGuardHome 装到 `/usr/bin/AdGuardHome`，工作目录 `/etc/proxy/agh`；
- 把 mihomo 装到 `/etc/proxy/core/mihomo`（或在 `sh/env.local.conf` 改 `CORE_BIN`）。

#### 2. 一键拉取本仓库

```sh
mkdir -p /etc/proxy/sh && cd /etc/proxy/sh
wget -O- https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/inst.sh | sh
```

`download-all-scripts.sh` 会自动识别为 openwrt，把 `init.d/{proxy_core,agh}` 与 `hotplug.d/net/99-meta-route` 装到 `/etc/`。

#### 3. 配置本地敏感参数

`/etc/proxy/core/local.conf` 写入：

```
SUBSCRIBE_URL=https://api.subcsub.com/sub?target=clash&url=<你的订阅 URL，URL-encoded>
sshSOS_password=...
sshSOS_user=...
sshSOS_server=...
sshSOS_port=22
```

如需覆盖默认端口/路径，再写 `/etc/proxy/sh/env.local.conf`，例如：

```
PROXY_HTTP=http://127.0.0.1:17890
CORE_BIN=/etc/proxy/core/sing-box-clash
```

#### 4. 首次刷新并启动

```sh
sh /etc/proxy/sh/update-all-configs.sh
service proxy_core enable && service proxy_core start
service agh enable && service agh start
```

#### 5. 推荐计划任务（cron）

```cron
*/5 * * * * sh /etc/proxy/sh/keeplive.sh
0   3 * * * sh /etc/proxy/sh/update-proxy-rule.sh
0   4 * * * sh /etc/proxy/sh/update-all-configs-restart-services.sh
```

### Debian / Ubuntu

#### 1. 准备目录与依赖

```sh
sudo mkdir -p /etc/proxy/{sh,core,agh}
sudo apt install -y curl wget util-linux iproute2
```

把 mihomo 解压到 `/etc/proxy/core/mihomo`（`chmod +x`），AGH 解压到 `/usr/bin/AdGuardHome`（`chmod +x`）。

> Debian 上需要打开 IPv4 转发：`echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-myproxy.conf && sudo sysctl --system`。如果用 `nftables` / `iptables` 防火墙，请放行 `7890` / `3721` / `253` / `53`。

#### 2. 一键拉取本仓库

```sh
sudo sh -c 'cd /etc/proxy/sh && wget -O- https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/inst.sh | sh'
```

`download-all-scripts.sh` 会自动识别为 systemd，把 `proxy_core.service` 与 `agh.service` 装到 `/etc/systemd/system/` 并执行 `systemctl daemon-reload`。

#### 3. 配置本地敏感参数

同 OpenWrt：填写 `/etc/proxy/core/local.conf` 与（可选）`/etc/proxy/sh/env.local.conf`。

#### 4. 首次刷新并启动

```sh
sudo sh /etc/proxy/sh/update-all-configs.sh
sudo systemctl enable --now proxy_core.service
sudo systemctl enable --now agh.service
```

观察日志：

```sh
journalctl -t MyProxy -f                  # 全部带 MyProxy tag 的脚本日志
journalctl -u proxy_core.service -f       # 内核 stdout / stderr
```

#### 5. 推荐计划任务

可继续用 cron（`/etc/cron.d/myproxy`），也可用 systemd timer：

```ini
# /etc/systemd/system/myproxy-keeplive.timer
[Unit]
Description=MyProxy keeplive
[Timer]
OnCalendar=*:0/5
Persistent=true
[Install]
WantedBy=timers.target

# /etc/systemd/system/myproxy-keeplive.service
[Unit]
Description=MyProxy keeplive runner
[Service]
Type=oneshot
ExecStart=/etc/proxy/sh/keeplive.sh
```

```sh
sudo systemctl enable --now myproxy-keeplive.timer
```

`update-proxy-rule.sh` 与 `update-all-configs-restart-services.sh` 同理，按需做对应 service+timer。

#### 6. 关于路由修正

mihomo 在 Debian 启动 TUN 后同样会把 fake-ip 路由加成 `/30`。`proxy_core.service` 的 `ExecStartPost` 会调用 `setup-fake-ip-route.sh`，等 TUN 接口就绪后自动修正成 `${FAKE_IP_CIDR}`，**无须** networkd-dispatcher / if-up.d 这类额外集成。如果你重启 mihomo 后仍要再次修路由，`systemctl restart proxy_core` 即可，ExecStartPost 会再跑一次。

---

## 从旧版（meta/ + clash_meta）迁移

如果你之前部署过本仓库的旧版本（目录是 `meta/`、服务是 `clash_meta`），按以下步骤迁移：

```sh
# 1. 停掉旧服务
/etc/init.d/clash_meta stop
/etc/init.d/clash_meta disable

# 2. 迁移工作目录（保留你的 local.conf 与 proxy/ 缓存）
mv /etc/proxy/meta /etc/proxy/core

# 3. 重新拉取脚本与 init 文件
sh /etc/proxy/sh/inst.sh

# 4. 删除旧 init.d
rm -f /etc/init.d/clash_meta

# 5. 启动新服务
service proxy_core enable && service proxy_core start
```

老的 `update-clash-config.sh` / `update-meta-config.sh` 已不存在；新版只有 `update-core-config.sh`。

---

## 日常运维

| 操作 | 命令 |
| --- | --- |
| 全量刷新规则 + 重启服务 | `sh /etc/proxy/sh/update-all-configs-restart-services.sh` |
| 仅刷新规则不重启 | `sh /etc/proxy/sh/update-all-configs.sh` |
| 仅刷新订阅 / `rule_gpt` | `sh /etc/proxy/sh/update-proxy-rule.sh` |
| 仅重新生成 AGH 的 `dns.conf` | `sh /etc/proxy/sh/update-agh-config.sh` |
| 跳过自更新 | 任一脚本加 `--noupdate` |
| 清空 fake-ip 缓存 | `curl -X POST $CORE_API/cache/fakeip/flush` |
| 看带 tag 的日志（OpenWrt） | `logread -e MyProxy -f` |
| 看带 tag 的日志（Debian） | `journalctl -t MyProxy -f` |
| 内核日志（Debian） | `journalctl -u proxy_core -f` |
| 重启服务（两个平台都可用） | `service proxy_core restart && service agh restart` |

新增 / 删除分流域名：直接编辑 `domain/myproxylist.txt` 或 `domain/gpt.txt`，push 到 `main`。下一次 cron 触发或手动 `update-all-configs.sh` 时，AGH 与代理内核都会拉到最新版本。

---

## 关键端口与目录约定

| 端口 / 路径 | 用途 |
| --- | --- |
| `:53/udp` | AdGuardHome 对客户端的 DNS 入口 |
| `:253` | 代理内核内置 DNS（fake-ip 出口），由 `CORE_DNS_PORT` 控制 |
| `:7890` | 代理内核 mixed-port，由 `PROXY_HTTP` 控制 |
| `:7893` | 代理内核 tproxy-port |
| `:853` | 代理内核 `tunnels` 段提供的 DoT-style TCP/UDP 隧道，转到 `8.8.8.8:53` |
| `:3721` | 代理内核外部控制器，由 `CORE_API` 控制 |
| `${FAKE_IP_CIDR}` | fake-ip 网段，由 hotplug 路由到 TUN |
| `/etc/proxy/sh/` | 所有脚本、`env.conf`、`env.local.conf` |
| `${AGH_DIR}` | AdGuardHome 工作目录（`agh.yaml`、生成的 `dns.conf`、`download/`） |
| `${CORE_DIR}` | 代理内核工作目录（二进制、`config.yaml`、`local.conf`、`proxy/`、`ruleset/`） |
| `/etc/init.d/{agh,proxy_core}` | OpenWrt 服务 |
| `/etc/hotplug.d/net/99-meta-route` | OpenWrt：TUN 路由热插拔 |
| `/etc/systemd/system/{agh,proxy_core}.service` | Debian/Ubuntu：systemd 单元 |

---

## 设计要点

1. **DNS 与代理双层分流**：AGH 决定"哪些域名要被代理"，代理内核决定"被代理的域名走哪个出口"。任一层修改都不牵动另一层。
2. **fake-ip + 路由修正**：mihomo 启动 TUN 时会把 fake-ip 路由错加成 `/30`（不论配置怎么写）。`setup-fake-ip-route.sh` 通过先删后加的方式修正：OpenWrt 由 hotplug 触发，Debian 由 `proxy_core.service` 的 `ExecStartPost` 触发，同一段实现共用。
3. **脚本自更新 + `--noupdate` 防递归**：单点维护、批量生效；自更新时透传原始参数，避免命令行被吞。
4. **占位符模板 + local.conf**：仓库可公开，敏感数据完全留在设备本地。`awk` 严格按第一个 `=` 切分，避免正则注入。
5. **下载稳健**：默认走代理；代理不可用时自动直连回退；临时文件 `mktemp` + 大小校验 + 原子替换。
6. **配置坏了不上线**：`update-core-config.sh` 校验失败保留旧 `config.yaml`；`update-all-configs-restart-services.sh` 任一步失败就不重启服务。
7. **provider 自动发现**：`update-proxy-rule.sh` 从 `config.yaml` 读出所有 provider 自动 PUT；增减 provider 不再需要同步改脚本。
8. **集中配置 + 通用命名**：`sh/env.conf` 收敛硬编码，`core/proxy_core/CORE_BIN` 全部用通用词，未来换内核或迁移仓库都只改一处。
9. **跨平台**：相同的 `sh/` 脚本同时跑在 OpenWrt（BusyBox `sh`）和 Debian/Ubuntu（dash）上，全部用 POSIX 子集；OS 差异只体现在服务文件层面（procd vs systemd），由 `download-all-scripts.sh` 在安装时按系统分发。
9. **保活**：`keeplive.sh` 配合 `disable-keep-alive: true`、`keep-alive-idle: 1800` 缓解长连断流；探测流量必须经过代理链路，确保探测的是真实出口。
