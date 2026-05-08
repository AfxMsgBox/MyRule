# MyRule

面向 OpenWrt（或类似嵌入式 Linux）路由器的一套 **AdGuardHome + Clash / Mihomo (Meta)** 透明代理与分流方案。仓库里集中维护：

- 一组**可自我更新**的 shell 脚本（每次执行先从 GitHub 拉到最新版本再继续运行）；
- Clash / Mihomo 的主配置模板与本地占位符注入机制；
- AdGuardHome 用到的自定义上游 / 过滤条目；
- 在 AGH 和 Clash 之间共享的分流域名清单；
- OpenWrt 的 `procd` 服务文件与 `hotplug` 路由处理。

部署后只要把脚本和服务文件放到路由上，后续新增/修改规则只需 push 到本仓库的 `main` 分支，下一次自动任务执行时就会自我同步并重载相关服务。

---

## 目录

- [整体架构](#整体架构)
  - [数据面：DNS → fake-ip → TUN](#数据面dns--fake-ip--tun)
  - [控制面：自更新脚本与配置注入](#控制面自更新脚本与配置注入)
- [仓库目录结构](#仓库目录结构)
- [文件逐一说明](#文件逐一说明)
  - [sh/ 脚本](#sh-脚本)
  - [sh/etc/ OpenWrt 服务与热插拔](#shetc-openwrt-服务与热插拔)
  - [meta/ Mihomo 配置](#meta-mihomo-配置)
  - [agh/ AdGuardHome 自定义片段](#agh-adguardhome-自定义片段)
  - [domain/ 分流域名清单](#domain-分流域名清单)
- [安装与部署](#安装与部署)
- [日常运维](#日常运维)
- [关键端口与目录约定](#关键端口与目录约定)
- [设计要点](#设计要点)

---

## 整体架构

### 数据面：DNS → fake-ip → TUN

```
┌──────────────┐     53/udp      ┌──────────────────┐
│  局域网客户端 │ ──────────────▶ │   AdGuardHome    │
└──────────────┘                  │ (/etc/proxy/agh) │
        ▲                         └────────┬─────────┘
        │ 直连域名                         │
        │ 国内 DNS 直接应答                 │ 命中分流列表的域名
        │                                  ▼
        │                         127.0.0.1:253（Clash 内置 DNS）
        │                                  │
        │                                  │ 返回 fake-ip
        │                                  ▼
        │                         172.16.0.0/12 网段地址
        │                                  │
        │                                  │ 客户端访问 fake-ip
        │                                  ▼
        │                         OpenWrt 路由表
        │                                  │  hotplug 把 172.16.0.0/12 指向 utun
        │                                  ▼
        │                         Clash / Mihomo (TUN: utun)
        │                                  │
        │                                  │ 按 rules / proxy-groups 选择出口
        │                                  ▼
        └────────────────────── HongKong / TaiWan / Singapore / USA / sshSOS
```

要点：

1. **AdGuardHome 充当唯一 DNS 入口**：根据 `dns.conf`（由 `update-agh-config.sh` 生成）决定域名是直接解析还是把请求改写转发到 `127.0.0.1:253`。
2. **Clash / Mihomo 在 :253 提供 fake-ip**：被分流的域名会拿到 `172.16.0.0/12` 网段的 fake-ip。
3. **TUN 接管 fake-ip 流量**：`meta/config.yaml` 启用了 `tun.enable: true, device: utun, stack: mixed`，并且把 `auto-route` 关闭，由 `99-meta-route` 这个 hotplug 脚本在 TUN 接口上线时把 `172.16.0.0/12` 路由挂到 `utun`。
4. **Clash 按规则选择出口**：`rule-providers.rule_gpt` 远程拉取本仓库的 `domain/gpt.txt`，命中后走 `gptProxy`；其余命中 fake-ip 的流量走 `defaultProxy`。两个策略组都是在 `fastHongKong / fastTaiWan / fastSingapore / fastUSA / sshSOS` 之间选择。
5. **节点订阅按地区拆分**：`proxy-providers` 用同一个 `SUBSCRIBE_URL` 但带不同 `include` 关键字（香港 / 台湾 / 新加坡 / 美国），各自做 `url-test` 健康检查。

### 控制面：自更新脚本与配置注入

```
GitHub: AfxMsgBox/MyRule
        │
        │ wget inst.sh | sh                （首次安装）
        ▼
inst.sh ─▶ download-all-scripts.sh ─▶ 把脚本/服务/hotplug 全部下载到本地
                                       └──▶ /etc/init.d/{agh, clash_meta}
                                       └──▶ /etc/hotplug.d/net/99-meta-route
                                       └──▶ ./common.sh, ./update-*.sh, ./keeplive.sh
        │
        │ cron 周期触发
        ▼
update-all-configs(-restart-services).sh
        │
        ├─ source common.sh                 ── 提供下载 / 替换占位符 / 日志函数
        │      └─ 每个脚本启动时会先用 common.sh 把自己升级到最新再 exec 重启
        │
        ├─ update-agh-config.sh             ── 拼装 agh/dns.conf
        ├─ update-clash-config.sh           ── 拉模板 → 用 clash/local.conf 替换占位符
        ├─ update-meta-config.sh            ── 拉模板 → 用 meta/local.conf 替换占位符
        └─ update-proxy-rule.sh             ── 调用 Clash REST API 刷新订阅 / 规则集
```

要点：

- **脚本自更新**：每个 `update-*.sh` 顶部都设置 `URL_SCRIPT` 指向自己的 GitHub Raw 路径，并 `source common.sh`。`common.sh` 启动时若没有传 `--noupdate`，会先把自身覆盖更新，然后 `exec sh $0 --noupdate`。这样推一次仓库，所有部署点都会自动同步。
- **占位符 + local.conf**：仓库里只放可公开的配置模板（含 `{SUBSCRIBE_URL}`、`{sshSOS_*}` 等占位符）。`local.conf` 里以 `key=value` 写敏感数据（订阅链接、SSH 凭据），**不进仓库**。`common.sh` 里 `replace_strings_from_config` 用 `awk` 严格按第一个 `=` 切分键值，再以 `{key}` 形式做纯字符串替换，避免正则注入与歧义。
- **下载稳健性**：`download_file` 默认通过本地 `127.0.0.1:7890`（Clash 的 mixed-port）下载，写到临时文件，校验 `>8` 字节再覆盖目标，避免半截文件破坏现有配置；同时自动备份旧 `config.yaml` 为 `config.yaml.bak`。
- **关闭自更新的口子**：所有脚本可用 `--noupdate` 跳过自我升级（被 `update-all-configs.sh` 串行调用时即采用此选项，避免反复重入）。

---

## 仓库目录结构

```
.
├── README.md
├── sh/
│   ├── inst.sh                                  # 一键安装入口（一行 wget | sh）
│   ├── download-all-scripts.sh                  # 把仓库的脚本与服务文件下载到本地
│   ├── common.sh                                # 公共函数库（下载 / 替换 / 自更新）
│   ├── update-all-configs.sh                    # 串行刷新四类配置
│   ├── update-all-configs-restart-services.sh   # 刷新后重启 agh / clash_meta
│   ├── update-agh-config.sh                     # 生成 AdGuardHome 的 dns.conf
│   ├── update-clash-config.sh                   # 生成 clash/config.yaml（占位符替换）
│   ├── update-meta-config.sh                    # 生成 meta/config.yaml（占位符替换）
│   ├── update-proxy-rule.sh                     # 通过 REST API 触发 Clash 重新拉取规则
│   ├── keeplive.sh                              # 周期保活（避免长连 idle 断流）
│   └── etc/
│       ├── init.d/agh                           # AdGuardHome 的 procd 服务
│       ├── init.d/clash_meta                    # Clash / Mihomo 的 procd 服务
│       └── hotplug.d/net/99-meta-route          # TUN 接口上线时挂 fake-ip 路由
├── agh/
│   ├── myupstream.txt                           # 自定义上游 DNS（域名→指定 DNS）
│   └── myfilter.txt                             # 自定义过滤 / hosts 条目
├── meta/
│   ├── config.yaml                              # Mihomo 主配置模板（含 {占位符}）
│   └── local.conf                               # 本地敏感参数（key=value）
└── domain/
    ├── myproxylist.txt                          # 常用代理域名（payload 列表）
    └── gpt.txt                                  # AI / Google 等专用分流域名
```

> 没有 `clash/` 目录是因为 Mihomo (`meta/`) 已经覆盖；`update-clash-config.sh` 仍保留以兼容旧部署：当本地存在 `clash/local.conf` 时它才会工作。

---

## 文件逐一说明

### sh/ 脚本

#### `sh/inst.sh`（3 行）
一键安装入口。等价于：

```sh
wget -O- https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/download-all-scripts.sh | sh
```

第一行的注释 `curl -X POST http://127.0.0.1:3721/cache/fakeip/flush && ping www.google.com` 是常用调试命令的备忘录：在改动 fake-ip 范围或规则后，需要清掉 Clash 已有的 fake-ip 映射并触发一次 DNS。

#### `sh/download-all-scripts.sh`（42 行）
把仓库所有要部署的脚本与服务文件 `wget` 到本地：

- 把 `common.sh / keeplive.sh / update-*.sh` 下载到与本脚本同目录；
- 把 `99-meta-route` 写入 `/etc/hotplug.d/net/`；
- 把 `clash_meta`、`agh` 两个 init 脚本写入 `/etc/init.d/` 并 `chmod +x`；
- 最后再下载 `download-all-scripts.sh` 自身和 `inst.sh`，使本机始终保有最新的安装器。

整个脚本只用 `wget`，不依赖 `common.sh`，便于在还没有任何依赖时引导。

#### `sh/common.sh`（83 行）
所有更新脚本共享的「框架」，提供三类能力：

1. **辅助函数**
   - `get_file_size <path>`：返回文件大小，文件不存在时返回 `0`。
   - `echo_log <msg> [tag]`：同时 `echo` 到标准输出和 `logger` 到系统日志，便于在 OpenWrt 的 `logread` 中追踪。

2. **稳健下载** `download_file <url> <dst> [bUseProxy=1]`
   - 默认走 `http://127.0.0.1:7890`（即 Clash 的 mixed-port），保证更新通道不受 GFW 影响；
   - `--connect-timeout 10`，超时即失败；
   - 写到 `/tmp/download_temp` 临时文件，体积 `<=8B` 视作失败并清理；
   - 通过后再 `mv` 覆盖目标，**避免半截文件**。

3. **占位符替换** `replace_strings_from_config <kv_file> <template>`
   - 用 `awk` 双文件模式：第一阶段把 `kv_file` 解析成字典，键名以 `{key}` 形式存入；第二阶段对模板逐行做 `index()` 字符串查找替换；
   - 严格以**第一个 `=`** 为界切分键值，因此 `value` 内允许出现 `=`；
   - 结果写入 `${target}.tmp` 后原子替换，失败则保留原文件。

4. **自更新逻辑（脚本尾部）**
   ```sh
   _URL_SCRIPT="${URL_SCRIPT:-$_URL_COMMON_SH}"
   if [ "$1" != "--noupdate" ] && [ -n "$_URL_SCRIPT" ]; then
       if download_file $_URL_SCRIPT $PATH_SCRIPT; then
           exec sh $PATH_SCRIPT --noupdate
       fi
   fi
   ```
   每个 `update-*.sh` 在 `source common.sh` 之前都会设 `URL_SCRIPT=` 自己的 raw 地址，于是 `source` 进来时这段逻辑就会拿来更新调用方脚本（而不是 `common.sh` 自己——`common.sh` 只在被 `sh common.sh` 直接执行时用 `_URL_COMMON_SH` 兜底）。

#### `sh/update-all-configs.sh`（32 行）
顶层编排器：

1. 先 `sh common.sh` 把 `common.sh` 自己升级一次（这次会触发 `_URL_COMMON_SH` 的自更新分支）；
2. 再 `source common.sh`，并把 `URL_SCRIPT` 设为本脚本，使本脚本下次也能被 `common.sh` 升级；
3. 依次 `download_file` 拉取并执行 `update-agh-config.sh`、`update-clash-config.sh`、`update-meta-config.sh`、`update-proxy-rule.sh`，每次都加 `--noupdate`，让被调脚本跳过自更新（避免无限套娃）。

#### `sh/update-all-configs-restart-services.sh`（10 行）
在 `update-all-configs.sh` 的基础上额外执行：

```sh
service agh restart
service clash_meta restart
```

适合做计划任务里的「全量刷新 + 重载」入口。

#### `sh/update-agh-config.sh`（72 行）
生成 AdGuardHome 的 `dns.conf`，是整个 DNS 分流的核心。流程：

1. 创建 `agh/download/` 暂存目录；
2. 在 `dns.conf` 顶部写入时间戳；
3. **默认上游**：若存在 `agh/local.dns.conf` 就追加它（自带本地 DNS 列表），否则把 `ip route | grep default | awk '{print $3}'` 取到的网关 IP 作为唯一上游；
4. 依次下载并合并下面五份列表（每份都先校验体积，再追加段头注释，再追加内容）：
   | 来源 | URL | 用途 |
   | --- | --- | --- |
   | 本仓库 `agh/myupstream.txt` | 直接 `cat` | 自定义域名 → 指定 DNS |
   | 本仓库 `domain/myproxylist.txt` | 经 `sed` 转换 | payload YAML → AGH 转发规则 |
   | 本仓库 `domain/gpt.txt` | 经 `sed` 转换 | 同上 |
   | `Loyalsoldier/clash-rules` 的 `tld-not-cn.txt` | 经 `sed` 转换 | 非 CN 顶级域 |
   | `Loyalsoldier/clash-rules` 的 `gfw.txt` | 经 `sed` 转换 | GFW 列表 |
5. **核心转换** —— 用一个 `sed` 把 Clash payload 行变成 AGH 的转发规则：
   ```
   - '+.example.com'   →   [/example.com/]127.0.0.1:253
   - 'foo.bar'         →   [/foo.bar/]127.0.0.1:253
   ```
   即：**让所有命中分流的域名解析都被 AGH 转发到 Clash 的内置 DNS（:253），从而拿到 fake-ip。**
6. 针对 `tld-not-cn.txt` 里会出现的 `.bj` 顶级域，额外 `sed -i '/\[\/bj\/\]/d'` 删除，避免误伤局域网/北京政企域名。

#### `sh/update-clash-config.sh`（21 行）/ `sh/update-meta-config.sh`（21 行）
两段几乎相同，只是工作目录与上游模板不同：

- `meta/` 版下载 `https://…/meta/config.yaml`，针对 Mihomo；
- `clash/` 版下载 `https://…/clash/config.yaml`（仓库未带，留给老用户）。

执行流程：

1. 仅当本地存在 `local.conf` 时才工作（保护未配置的设备）；
2. `download_file` 把模板存到 `config.new`；
3. `replace_strings_from_config local.conf config.new` 把 `{占位符}` 替换；
4. 把现有 `config.yaml` 备份成 `config.yaml.bak`，再用 `config.new` 覆盖之。

#### `sh/update-proxy-rule.sh`（27 行）
不重启进程，通过 Clash 的 RESTful 外部控制器（`:3721`）刷新订阅与规则集：

```
PUT /providers/proxies/TaiWan
PUT /providers/proxies/HongKong
PUT /providers/proxies/Singapore
PUT /providers/proxies/USA
PUT /providers/rules/rule_gpt
```

每次之间 `sleep 2s`，避免对源站短时间高并发。该脚本顶部注释写明了推荐的 cron：`0 3 * * * sh /etc/proxy/sh/update-proxy-rule.sh`。

#### `sh/keeplive.sh`（5 行）
通过本地 7890 端口分别 `curl -I https://www.google.com` 和 `https://www.chatgpt.com`：

- 用途：定时触发出口流量，让节点的长连接保持活跃，缓解部分机场/线路在 idle 一段时间后掉线的问题（参见注释中引用的 [OpenClash issue #2614](https://github.com/vernesong/OpenClash/issues/2614)）；
- 推荐 cron：`*/5 * * * * sh /etc/proxy/sh/keeplive.sh`。

### sh/etc/ OpenWrt 服务与热插拔

#### `sh/etc/init.d/agh`（21 行）
OpenWrt 的 `procd` 服务文件，启动 `/usr/bin/AdGuardHome`：

- 工作目录 `/etc/proxy/agh`；
- 配置文件 `/etc/proxy/agh/agh.yaml`（**注意**：这是 AdGuardHome 自身的主配置，不是本仓库管理的 `dns.conf`，`dns.conf` 是被 `agh.yaml` 通过 `dns.upstream_dns_file` 之类的字段引用的子文件）；
- `--no-check-update` 关闭自检升级；
- `START=99 / STOP=1`：启动时序排在最后、停止时序排在最先，以确保 DNS 服务最晚停最早起。

#### `sh/etc/init.d/clash_meta`（30 行）
启动 Clash 或 Mihomo 的 `procd` 服务，并自动选择内核：

```sh
if [ -e /etc/proxy/meta/mihomo ]; then
    CLASH_PROG=/etc/proxy/meta/mihomo
    CLASH_DIR=/etc/proxy/meta
else
    CLASH_PROG=/etc/proxy/clash/clash
    CLASH_DIR=/etc/proxy/clash
fi
```

`procd_set_param respawn` 会在异常退出时自动拉起。`START=98 / STOP=2` 紧邻 AGH，保证 DNS（99）先启动、代理（98）随后跟上。

#### `sh/etc/hotplug.d/net/99-meta-route`（7 行）
当网卡接口 `add` 事件发生且名字为 `Meta` 或 `utun` 时：

```sh
ip route del 172.16.0.0/30        # 清掉可能存在的占位短路由
ip route add 172.16.0.0/12 dev "$INTERFACE"
logger "Route added to $INTERFACE via hotplug"
```

把 fake-ip 网段路由到 TUN 设备。这就是为什么 `meta/config.yaml` 里 `tun.auto-route: false` 仍然能让流量送进 TUN——路由由这个 hotplug 脚本接管。

### meta/ Mihomo 配置

#### `meta/config.yaml`（184 行）
Mihomo / Clash Meta 的主配置模板。模板中所有 `{xxx}` 都需要 `local.conf` 提供。重点字段：

- **基础**：`mixed-port: 7890`、`tproxy-port: 7893`、`allow-lan: true`、`mode: rule`、`log-level: warning`、`ipv6: false`；
- **外部控制器**：`external-controller: :3721`，`external-ui: ui`，给 `update-proxy-rule.sh` 调用；
- **长连接**：`keep-alive-idle: 1800`、`keep-alive-interval: 60`、`disable-keep-alive: true`，配合 `keeplive.sh` 缓解 idle 断流；
- **Profile**：`store-selected / store-fake-ip` 都开，重启后保留选节点结果与 fake-ip 映射；
- **Tunnels**：在 `0.0.0.0:853` 监听 TCP/UDP，把请求隧道到 `8.8.8.8:53`，走 `defaultProxy`（用作加密 DNS over TCP 出口）；
- **TUN**：`device: utun`、`stack: mixed`、`mtu: 1400`、`auto-route: false`、`auto-redir: false`、`auto-detect-interface: false`，路由完全由 hotplug 脚本控制；
- **DNS**：`enhanced-mode: fake-ip`、`listen: :253`、`fake-ip-range: 172.16.0.1/12`，`nameserver`：`223.5.5.5 / 114.114.114.114`，`fallback`：`8.8.8.8`，并通过 `nameserver-policy` 单独把 `cp.paeadiy.com` 走 `47.116.209.9:39053`；
- **proxies**：内置一个 `sshSOS` 节点（`type: ssh`），凭据来自 `local.conf` 的 `{sshSOS_*}`；
- **proxy-providers**：四个 HTTP 订阅，URL 都是 `{SUBSCRIBE_URL}` 加不同的 `include` 关键字（百分号编码：香港 / 台湾 / 新加坡 / 美国），分别落到 `./proxy/<地区>.yaml`，每个都做 `health-check`（http://www.gstatic.com/generate_204）；
- **proxy-groups**：
  - `fastHongKong / fastTaiWan / fastSingapore / fastUSA`：`type: url-test`，自动选最快；
  - `defaultProxy`：手选，候选 `fastHongKong → fastTaiWan → fastSingapore → fastUSA → sshSOS`；
  - `gptProxy`：手选，候选顺序为 `fastSingapore → fastTaiWan → fastHongKong → fastUSA → sshSOS`（针对 OpenAI 等服务对地区敏感的特点把新加坡放第一）；
- **rule-providers**：`rule_gpt` 远程拉取本仓库 `domain/gpt.txt`，`behavior: domain`、间隔 86400s、用 `fastHongKong` 拉取；
- **rules**：仅两条 —— `RULE-SET,rule_gpt,gptProxy` 与 `MATCH, defaultProxy`。绝大部分分流交给 AGH + fake-ip 完成，Clash 这层只在 GPT 域名上做特殊出口选择。

#### `meta/local.conf`（5 行，仓库示例）
本地占位符值的来源：

```
SUBSCRIBE_URL=https://api.subcsub.com/sub?target=clash&url=
sshSOS_password=pass
sshSOS_user=user
sshSOS_server=8.8.8.8
sshSOS_port=22
```

实际部署要把 `SUBSCRIBE_URL` 后面拼上自己的订阅源 URL，并写入真实的 SSH 凭据。`update-meta-config.sh` 会把 `config.yaml` 中所有 `{KEY}` 用对应值替换。

### agh/ AdGuardHome 自定义片段

#### `agh/myupstream.txt`（2 行）
"特定域名 → 指定 DNS 服务器" 的自定义上游，会被 `update-agh-config.sh` 原样追加到 `dns.conf`：

```
[/cp.paeadiy.com/]47.116.209.9:39053
[/mynetname.net/]223.5.5.5
```

#### `agh/myfilter.txt`（1 行）
本地 hosts/过滤项（仓库当前只有一个示例 `5.5.5.5 oo.test`）。它**没有被脚本自动引用**，留给运维按需在 AdGuardHome 主配置中挂载，或作为自定义过滤规则的来源。

### domain/ 分流域名清单

两份文件都使用 Clash 的 `payload:` YAML 格式，单引号包裹，`+.` 表示通配子域：

#### `domain/myproxylist.txt`（74 行）
日常常用代理域名的集合，覆盖：

- 开发资源类：`docker.com / docker.io`、`gitbook.io`、`jsdelivr.net`、`v2ex.com`、`openwrt.org`、`raspberrypi.com`、`proxmox.com`、`hpe.com`、`mikrotik.com`、`metacubex.one`、`sagernet.org`、`freenas.org` 等；
- 媒体 / 流媒体：`tidal.com`、`steampowered.com`、`mobile01.com`、`khanacademy.org`；
- 通讯类：`t.me / tdesktop.com / telegra.ph / telegram.me / telegram.org / telesco.pe`；
- 游戏：`battle.net / blizzard.com / xboxlive.com`；
- 设备 / IoT：`bang-olufsen.com / azure-devices.net / westeurope.cloudapp.azure.com`；
- DDNS / Misc：`zhome.picp.vip / id.me / godaddy.com / docusign.com / citi.com / yahoo.com / ip138.com / cpubenchmark.net / 4d4y.com / clerksystems.com / doata.net / cncbinternational.com / notion.so / volumio.org / moodeaudio.org / roonlabs.com / roonlabs.net / roon.app`；
- 注释里的 IPv4/IPv6 段是 Telegram 官方公布的网络范围，留作"如果改成 IP 规则会用到"的备忘录。

这份列表会被 `update-agh-config.sh` 转换成 `[/domain/]127.0.0.1:253` 写进 `dns.conf`，从而让 AGH 把这些域名的解析全部转发给 Clash 的内置 DNS、拿 fake-ip。

#### `domain/gpt.txt`（62 行）
单独维护的"AI / 关键 SaaS"域名集合：

- **OpenAI 全家桶**：`openai.com / chatgpt.com / oaistatic.com / oaiusercontent.com / openaimerge.com / openaicom.imgix.net` 以及 CDN/鉴权依赖 `auth0.com / workos.com / workoscdn.com / cloudflare.com / statsig.com / statsigapi.net / featuregates.org / featureassets.org`；
- **OpenAI 后端 / Azure CDN**：`openai.com.cdn.cloudflare.net / openaiapi-site.azureedge.net / openaicom-api-…azurefd.net / openaicomproductionae4b.blob.core.windows.net / production-openaicom-storage.azureedge.net`；
- **Anthropic**：`anthropic.com / claude.ai / claude.com / claudeusercontent.com`；
- **OpenRouter**：`openrouter.ai`；
- **Google 全家桶**：`google.com / google.cn / google.com.hk / googleapis.com / googleapis.cn / googletagmanager.com / googleusercontent.com / googlevideo.com / gstatic.com / gvt1.com / ggpht.com / gmail.com / google-analytics.com / recaptcha.net / withgoogle.com / youtube.com / ytimg.com / android.com`；
- **Google AI**：`deepmind.com / deepmind.google / generativeai.google`；
- **微软 / Bing**：`bing.com / bing.net`；
- **Edge / Fastly**：`edgecompute.app / every1dns.net`。

这份文件**有两份用处**：

1. 同样会被 `update-agh-config.sh` 转成 AGH 的转发规则；
2. 同时被 `meta/config.yaml` 里的 `rule-providers.rule_gpt` 远程引用，作为 Clash 层"哪些域名走 `gptProxy`"的判定依据。两层判定串联起来才完成"AI 类域名走新加坡优先的策略组"这一目标。

---

## 安装与部署

> 假设设备是 OpenWrt，脚本工作根目录约定为 `/etc/proxy/`：`/etc/proxy/sh`、`/etc/proxy/agh`、`/etc/proxy/meta`。

### 1. 安装 AdGuardHome 与 Mihomo

按各自项目的方式安装到：

- `/usr/bin/AdGuardHome`，工作目录 `/etc/proxy/agh`；
- `/etc/proxy/meta/mihomo`（或 `/etc/proxy/clash/clash`，二选一）。

`init.d/clash_meta` 会自动判断使用哪一个。

### 2. 一键拉取本仓库的脚本

在 `/etc/proxy/sh` 下执行：

```sh
wget -O- https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/inst.sh | sh
```

执行后：

- 当前目录会得到全部 `*.sh`；
- `/etc/init.d/agh`、`/etc/init.d/clash_meta`、`/etc/hotplug.d/net/99-meta-route` 会被写入；
- 两个 init 脚本被赋予可执行权限。

### 3. 写入本地敏感参数

在 `/etc/proxy/meta/local.conf` 中填好：

```
SUBSCRIBE_URL=https://api.subcsub.com/sub?target=clash&url=<你的订阅 URL，已 URL-encoded>
sshSOS_password=...
sshSOS_user=...
sshSOS_server=...
sshSOS_port=22
```

如还在用 Clash Premium，可在 `/etc/proxy/clash/local.conf` 里填同样的键，`update-clash-config.sh` 会接管它。

### 4. 首次刷新并启动

```sh
sh /etc/proxy/sh/update-all-configs.sh
service agh enable && service agh start
service clash_meta enable && service clash_meta start
```

之后把路由器的上游 DNS 设成 AdGuardHome（一般是 `127.0.0.1` 或路由 LAN IP），再按需让客户端把网关 / DNS 指向路由即可。

### 5. 推荐的计划任务

```cron
*/5 * * * * sh /etc/proxy/sh/keeplive.sh
0   3 * * * sh /etc/proxy/sh/update-proxy-rule.sh
0   4 * * * sh /etc/proxy/sh/update-all-configs-restart-services.sh
```

---

## 日常运维

| 操作 | 命令 |
| --- | --- |
| 全量刷新规则 + 重启服务 | `sh /etc/proxy/sh/update-all-configs-restart-services.sh` |
| 仅刷新规则不重启 | `sh /etc/proxy/sh/update-all-configs.sh` |
| 仅刷新 Clash 订阅 / `rule_gpt` | `sh /etc/proxy/sh/update-proxy-rule.sh` |
| 仅重新生成 AGH 的 `dns.conf` | `sh /etc/proxy/sh/update-agh-config.sh` |
| 跳过自更新执行（调试） | 任一脚本加 `--noupdate` |
| 清空 fake-ip 缓存 | `curl -X POST http://127.0.0.1:3721/cache/fakeip/flush` |
| 看日志 | `logread -f`（脚本会通过 `logger` 写系统日志） |

新增分流域名：直接编辑 `domain/myproxylist.txt` 或 `domain/gpt.txt`，push 到 `main`。下一次 cron 触发或手动运行 `update-all-configs.sh` 时，AGH 与 Clash 都会拉到最新版本。

---

## 关键端口与目录约定

| 端口 / 路径 | 用途 |
| --- | --- |
| `:53/udp` | AdGuardHome 对客户端的 DNS 入口 |
| `:253` | Clash / Mihomo 内部 DNS（fake-ip 出口） |
| `:7890` | Clash mixed-port（HTTP / SOCKS5）。`download_file` 默认通过它出去，`keeplive.sh` 也用它发探测包 |
| `:7893` | Clash tproxy-port |
| `:853` | Clash `tunnels` 段提供的 DoT-style TCP/UDP 隧道，转到 `8.8.8.8:53` |
| `:3721` | Clash 外部控制器（`update-proxy-rule.sh` 推 PUT） |
| `172.16.0.0/12` | fake-ip 网段，由 hotplug 路由到 `utun` |
| `/etc/proxy/sh/` | 所有脚本与 `common.sh` 默认所在目录 |
| `/etc/proxy/agh/` | AdGuardHome 工作目录（含 `agh.yaml`、生成的 `dns.conf`、`download/`） |
| `/etc/proxy/meta/` | Mihomo 工作目录（含 `mihomo`、`config.yaml`、`local.conf`、订阅落地的 `proxy/`、规则落地的 `ruleset/`） |
| `/etc/init.d/{agh,clash_meta}` | OpenWrt 服务 |
| `/etc/hotplug.d/net/99-meta-route` | TUN 路由热插拔 |

---

## 设计要点

1. **DNS 与代理双层分流**：AGH 决定"哪些域名要被代理"，Clash 决定"被代理的域名走哪个出口"。任一层修改都不会牵动另一层，规则维护可以拆分给不同人。
2. **fake-ip + hotplug 路由**：避免 `auto-route` 在不同 Linux 版本下的兼容问题，把路由编排显式写在 hotplug 脚本里，便于排错。
3. **脚本自更新 + `--noupdate` 防递归**：单点维护、批量生效，又不会在被上层调用时反复重入。
4. **占位符模板 + local.conf**：仓库可公开，敏感数据完全留在设备本地，且替换逻辑用 `awk` 做纯字符串处理，杜绝正则注入。
5. **下载稳健**：所有下载都先到 `/tmp` 临时文件并校验大小，再原子替换；旧 `config.yaml` 备份成 `.bak` 以便回滚。
6. **Clash / Mihomo 自动兼容**：`init.d/clash_meta` 通过路径探测自动切换内核，从 Clash Premium 迁移到 Mihomo 不需要改 init 脚本。
7. **保活**：`keeplive.sh` 配合 `disable-keep-alive: true`、`keep-alive-idle: 1800` 缓解长连断流；同时通过 `7890` 出去而不是直接 `curl`，确保探测流量真的经过代理链路。
