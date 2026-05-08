# MyRule

面向 OpenWrt 路由器的一套「AdGuardHome + Clash/Mihomo (Meta)」透明代理与分流规则集合。仓库里同时包含：服务启动脚本、配置模板、域名规则集，以及一组可自我更新的 shell 脚本——这些脚本会在每次执行时先把自己从 GitHub 拉取最新版本，再继续完成更新配置、重载服务等工作。

## 仓库结构

```
.
├── sh/                              # 全部脚本（含 OpenWrt 服务/热插拔文件）
│   ├── inst.sh                      # 一键安装入口
│   ├── download-all-scripts.sh      # 下载/同步所有脚本到本地
│   ├── common.sh                    # 公共函数库（自更新 / 下载 / 模板替换）
│   ├── update-all-configs.sh        # 串行调用下面四个 update-* 脚本
│   ├── update-all-configs-restart-services.sh  # 更新后重启 agh / clash_meta
│   ├── update-agh-config.sh         # 拉取域名列表，生成 AdGuardHome 的 dns.conf
│   ├── update-clash-config.sh       # 用 local.conf 替换 clash/config.yaml 占位符
│   ├── update-meta-config.sh        # 用 local.conf 替换 meta/config.yaml 占位符
│   ├── update-proxy-rule.sh         # 通过 RESTful API 触发 Clash 重新拉取节点 / 规则
│   ├── keeplive.sh                  # 周期性触发代理出口连通（避免 idle 断流）
│   └── etc/
│       ├── init.d/agh               # AdGuardHome 的 procd 服务
│       ├── init.d/clash_meta        # Clash/Mihomo 的 procd 服务（自动选择 meta 或 clash）
│       └── hotplug.d/net/99-meta-route  # tun 接口起来后挂上 fake-ip 路由
├── agh/                             # AdGuardHome 相关
│   ├── myupstream.txt               # 自定义上游 DNS（特定域走特定 DNS 服务器）
│   └── myfilter.txt                 # 自定义过滤/hosts 规则
├── meta/                            # Mihomo (Clash Meta) 配置
│   ├── config.yaml                  # 主配置模板（含 {占位符}）
│   └── local.conf                   # 本地敏感参数（订阅链接、SSH 凭据），用于替换占位符
└── domain/                          # 分流域名清单（被 agh 与 Clash 共用）
    ├── myproxylist.txt              # 自定义需要走代理的域名（payload 格式）
    └── gpt.txt                      # AI / Google 等需要单独分流的域名
```

## 功能概览

### 1. 透明代理整体架构
- **AdGuardHome (agh)**：监听 53 端口做 DNS 上游，根据 `dns.conf` 把需要走代理的域名解析到 `127.0.0.1:253`。
- **Mihomo / Clash Meta**：在 `:253` 监听 DNS（fake-ip 模式，`172.16.0.0/12`），并启动 `utun` TUN 设备承接被劫持的流量。
- **OpenWrt 路由**：`hotplug.d/net/99-meta-route` 在 `Meta` / `utun` 接口上线时把 `172.16.0.0/12` 路由指向 TUN，从而把命中 fake-ip 的会话送进 Clash 出口。
- **节点订阅**：`meta/config.yaml` 中按地区拆分（HongKong / TaiWan / Singapore / USA）并各做 `url-test`，再由 `defaultProxy` / `gptProxy` 选择策略组；GPT 类域名通过 `rule_gpt`（远程拉取本仓库 `domain/gpt.txt`）单独走 `gptProxy`。

### 2. 可自更新的脚本框架（`sh/common.sh`）
所有 `update-*.sh` 都会在启动时 `source common.sh`，并设置 `URL_SCRIPT` 指向自己的 GitHub Raw 地址。`common.sh` 中：
- `download_file <url> <dst> [bUseProxy]`：通过本地 `127.0.0.1:7890` 代理下载，校验文件 > 8B 后才覆盖目标。
- `replace_strings_from_config <kv_file> <template>`：用 `awk` 把 `{key}` 形式占位符替换为本地 `local.conf` 中 `key=value` 的值（用于注入订阅链接、SSH 账密等敏感数据，避免提交到仓库）。
- `echo_log` / `get_file_size` 等工具函数。
- 启动时除非传入 `--noupdate`，会先把自己更新成 GitHub 最新版本再 `exec` 重启，因此一次推送即可让所有路由器同步最新逻辑。

### 3. 各脚本职责
| 脚本 | 用途 |
| --- | --- |
| `inst.sh` | 一键安装入口：`wget … download-all-scripts.sh \| sh` |
| `download-all-scripts.sh` | 把仓库中的脚本、`init.d` 服务、hotplug 文件下载到本地相应位置，并赋可执行权限 |
| `update-agh-config.sh` | 生成 `agh/dns.conf`：合并默认网关 / `local.dns.conf` + `myupstream.txt` + `myproxylist.txt` + `gpt.txt` + Loyalsoldier 的 `tld-not-cn.txt` 与 `gfw.txt`，所有需要走代理的域名都被改写成 `[/domain/]127.0.0.1:253` |
| `update-clash-config.sh` / `update-meta-config.sh` | 拉取最新 `config.yaml`，用本地 `local.conf` 替换占位符，备份旧配置为 `config.yaml.bak` 后启用新配置 |
| `update-proxy-rule.sh` | 调用 Clash 外部控制器（`:3721`）的 `/providers/proxies/{name}` 与 `/providers/rules/rule_gpt`，强制刷新订阅与规则集 |
| `update-all-configs.sh` | 串行执行 agh / clash / meta / proxy-rule 四个更新脚本 |
| `update-all-configs-restart-services.sh` | 在更新后调用 `service agh restart` 与 `service clash_meta restart` |
| `keeplive.sh` | 通过本地 7890 代理周期性 `curl` Google / ChatGPT，保持长连接活跃，缓解 OpenClash 长连 idle 问题 |

### 4. OpenWrt 服务与热插拔
- `etc/init.d/agh`：用 procd 拉起 `/usr/bin/AdGuardHome`，工作目录 `/etc/proxy/agh`，配置文件 `agh.yaml`。
- `etc/init.d/clash_meta`：优先使用 `/etc/proxy/meta/mihomo`（如果存在），否则回退到 `/etc/proxy/clash/clash`，便于在 Clash 与 Mihomo 之间无缝切换。
- `etc/hotplug.d/net/99-meta-route`：当 `Meta` 或 `utun` 接口 `add` 时，把 `172.16.0.0/12` 路由挂到该接口（删除可能已经存在的 `/30` 占位）。

### 5. 域名规则集
- `domain/myproxylist.txt`：日常需要代理的常用站点（GitHub 资源、Docker、Steam、Tidal、Telegram、Blizzard、B&O 等）。
- `domain/gpt.txt`：AI 服务域名集合（OpenAI、Anthropic Claude、Google/Gemini、Bing、相关 CDN 与鉴权域）；同时被 Clash 通过 `rule_gpt` 远程引用作为 `RULE-SET`。
- `agh/myupstream.txt`：少量域名用指定 DNS 解析。
- `agh/myfilter.txt`：自定义 hosts/过滤条目。

## 安装与使用

### 一键安装（OpenWrt）
```sh
wget -O- https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/inst.sh | sh
```
脚本会调用 `download-all-scripts.sh`，把全部脚本与服务文件下载到当前目录及 `/etc/init.d/`、`/etc/hotplug.d/net/` 下。

### 配置本地敏感信息
在 `meta/local.conf`（或对应的 `clash/local.conf`）中按 `key=value` 形式写入：
```
SUBSCRIBE_URL=https://api.subcsub.com/sub?target=clash&url=<your-sub>
sshSOS_password=...
sshSOS_user=...
sshSOS_server=...
sshSOS_port=22
```
之后 `update-meta-config.sh` 会自动把模板中的 `{SUBSCRIBE_URL}` 等占位符替换掉，敏感数据不会进入仓库。

### 定时任务示例
```cron
*/5 * * * * sh /etc/proxy/sh/keeplive.sh
0   3 * * * sh /etc/proxy/sh/update-proxy-rule.sh
0   4 * * * sh /etc/proxy/sh/update-all-configs-restart-services.sh
```

### 手动操作
```sh
# 强制全量刷新订阅与规则
sh /etc/proxy/sh/update-all-configs-restart-services.sh

# 仅刷新 Clash 订阅 / 规则（无需重启）
sh /etc/proxy/sh/update-proxy-rule.sh

# 跳过自更新逻辑直接执行
sh /etc/proxy/sh/update-agh-config.sh --noupdate
```

## 关键端口

| 端口 | 用途 |
| --- | --- |
| 7890 | Clash mixed-port（HTTP/SOCKS） |
| 7893 | Clash tproxy-port |
| 853  | DNS over TCP/UDP tunnel → `8.8.8.8:53`（走 `defaultProxy`） |
| 253  | Clash 内置 DNS（fake-ip 输出端） |
| 3721 | Clash 外部控制器（被 `update-proxy-rule.sh` 调用） |

## 设计要点

- **占位符 + local.conf**：让仓库里只放可公开的模板，敏感参数与设备相关字段全部留给本地。
- **脚本自更新**：每个脚本都能从 GitHub 拉到最新版再执行，部署一次后的运维无需 SSH 上每台路由。
- **AdGuardHome 与 Clash 双层分流**：DNS 层先把目标域映射到 fake-ip 网段，再由 Clash 按规则出口；规则集既可走本地 `payload` 列表，也可远程引用 `rule_gpt`。
- **Meta / Clash 自动兼容**：`init.d/clash_meta` 自动判断使用哪一个内核，方便迁移到 Mihomo。
