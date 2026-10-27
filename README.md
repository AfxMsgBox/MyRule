# MyRule

用 AdGuardHome（AGH）和 Mihomo（Core）提供 DNS 过滤、分流及透明代理。默认安装目录 `/etc/proxy`；下文路径按此编写，自定义安装时替换。

## 1. 安装

目标机支持 **OpenWrt、使用 systemd 的 Linux**，需有 root/sudo 权限、可用软件源和 `/dev/net/tun`。发起端支持 Linux、macOS、OpenWrt；macOS 仅用于 SSH 部署。缺失工具会提示并补装，Mac 缺工具时需先有 Homebrew。

准备订阅 URL；首次下载需要代理时，按向导填写代理地址。AGH 用户名默认 `admin`，可选择免登录；设置密码需填写 bcrypt 哈希（可用 `htpasswd -nB -C 10 admin` 生成，取 `admin:` 后的部分）。

### 在线安装：只需一个 inst.sh

在目标机或 SSH 发起端下载并运行（本机安装以 root 运行）：

```sh
curl -fL -o inst.sh https://raw.githubusercontent.com/AfxMsgBox/MyRule/refs/heads/claude/update-readme-overview-pU5D3/sh/inst.sh
sh inst.sh
```

也可用浏览器下载。上例为当前开发分支，向导中选同一分支；其它分支需包含新版安装器。

### 本地仓库安装：使用 ZIP 或开发目录

在 GitHub 选择分支，点击 **Code → Download ZIP**，解压后运行。文件名按实际下载替换：

```sh
unzip MyRule-分支名.zip
cd MyRule-分支名
sh sh/inst.sh
```

已有开发仓库则直接运行其中的 `sh/inst.sh`。本地源目录自动识别，不要把安装目录放在源目录内。

### 向导中的四种方式

| 选择 | 在哪里运行 | 文件来源 |
|---|---|---|
| 本机安装（在线下载） | 目标机 | 从 GitHub 下载并安装到本机 |
| SSH 安装（在线下载） | 能访问下载源的设备 | 下载全部项目资源，再通过 SSH 上传安装 |
| SSH 安装（使用本地仓库） | 开发机的仓库目录 | 本地代码＋在线外部资源，再通过 SSH 上传安装 |
| 本机安装（使用本地仓库） | 目标机的仓库目录 | 本地代码＋在线外部资源，安装到本机 |

SSH 支持用户名、密码和密钥；目标机只需能访问软件源补齐依赖。**本地仓库安装仍需联网**获取程序、订阅和外部规则。所有方式均选择后续更新分支；重装会覆盖项目管理的文件，保留运行数据。以后更新直接从 GitHub 获取，不再依赖发起端或原仓库目录。

向导中可设置每隔几天更新脚本和配置。输入均可见，回车采用默认值；SSH/sudo 密码除外。

保存输入，方便重复安装：

```sh
sh inst.sh --fill-from              # 使用脚本同目录 myrule.inst.cfg
sh inst.sh --fill-from ./debug.cfg  # 使用指定文件
```

已有值作为默认值，每次输入立即保存；缺项使用脚本默认值。不带此参数则不读写配置文件。文件含订阅等私密信息，SSH 密码不保存。

命令行安装及所有参数说明见 `sh inst.sh --help`（也支持 `-h`、`help`）。

## 2. 日常维护

默认管理页面：AGH `http://设备IP:180`，Mihomo `http://设备IP:3721/ui/`。

在**安装设备**上执行：

| 操作 | 命令 |
|---|---|
| 更新所有脚本 | `sh /etc/proxy/sh/update-scripts.sh` |
| 更新配置、订阅、规则并重启 | `sh /etc/proxy/sh/update-all-configs-restart-services.sh` |
| 更新 Mihomo、AGH、面板 | `sh /etc/proxy/sh/update-bin.sh` |
| 查看自动更新任务 | `crontab -l` |
| OpenWrt 日志 | `logread -e MyProxy -f` |
| systemd 日志（脚本、Core、AGH） | `journalctl -t MyProxy -f` |

二进制更新成功后重启服务：

```sh
# systemd Linux
systemctl restart proxy_core agh
# OpenWrt
/etc/init.d/proxy_core restart && /etc/init.d/agh restart
```

安装日志位于入口脚本同目录的 `myrule.inst.log`，每次安装覆盖旧记录。下载命令含完整凭据；调试时复制“调试重放命令”下一行，结果写到当前目录，分享日志前清理私密内容。

## 3. env.local.conf

安装器生成 `/etc/proxy/sh/env.local.conf`，保存本机参数；更新脚本时保留。值用单引号包裹，不要提交到仓库。

| 变量 | 用途 |
|---|---|
| `MP_SUBSCRIBE_URL` | 节点订阅 URL |
| `MP_REPO_BRANCH` | 更新分支，空值为 `main` |
| `MP_PROXY` | 外部后备代理，空值不使用 |
| `MP_LOCAL_DNS` | 直连上游 DNS，空格分隔；空值使用系统 DNS |
| `MP_AGH_USER_NAME` | AGH 用户名，默认 `admin` |
| `MP_AGH_PASSWORD` | bcrypt 密码哈希；空值免登录 |
| `MP_INST_DIR` | 安装路径；不要通过修改此值迁移安装 |

修改后运行“更新配置、订阅、规则并重启”命令。长期分流规则改仓库 `domain/`；其它配置改仓库模板。**完整配置更新会覆盖 AGH 页面中的配置修改。**

## 4. 目录与脚本

| 目录 | 作用 |
|---|---|
| `sh/` | 安装、更新、卸载脚本及本机参数 |
| `sh/etc/` | systemd/OpenWrt 服务、hotplug 路由修复模板 |
| `core/` | 仓库中为 Mihomo 模板；安装后含程序、配置、订阅、面板 |
| `agh/` | 仓库中为 AGH 模板及自定义上游；安装后含程序、过滤规则和运行数据 |
| `domain/` | 仓库中的自定义分流域名 |
| `tests/` | 开发用回归测试 |
| `sh/.install-state/`、`sh/.schedule/` | 安装后生成的卸载恢复记录、自动更新状态 |

以下脚本均在 `sh/`，一般只需使用上面的维护命令：

| 文件 | 作用 |
|---|---|
| `inst.sh` | 安装入口和独立下载自举 |
| `install-lib.sh` | 向导、依赖检查、资源准备、安装 |
| `install-remote.sh` | SSH 探测、上传和远程部署 |
| `uninstall.sh` | 卸载服务、系统集成及可选数据清理 |
| `update-scripts.sh` | 更新全部脚本及已有服务文件 |
| `update-bin.sh` | 更新 Mihomo、AGH、面板 |
| `update-all-configs-restart-services.sh` | 更新全部配置并切换、重启服务 |
| `update-all-configs.sh` | 下载配置和规则，暂存 AGH 配置；不重启 |
| `update-core-config.sh` | 生成 Core 配置，预下载订阅及规则 |
| `update-agh-config.sh` | 生成 AGH 域名上游 `dns.conf` |
| `update-proxy-rule.sh` | 通过 Core API 刷新订阅和规则 |
| `setup-fake-ip-route.sh` | 修复、维护 fake-ip 到 TUN 的路由 |
| `run-scheduled-update.sh` | 按天数执行自动更新，防止重叠 |
| `keeplive.sh` | 通过 Core 发起保活请求；默认未安排任务 |
| `common.sh` | 配置解析、下载、渲染、服务控制公共函数 |
| `portable.sh` | 路径、校验、下载、日志等便携函数 |
| `env.conf` | 默认参数及 `env.local.conf` 加载逻辑 |
| `etc/init.d/agh`、`etc/init.d/proxy_core` | OpenWrt 的 AGH、Core 服务模板 |
| `etc/systemd/system/*.service` | systemd 的 AGH、Core 服务模板 |
| `etc/hotplug.d/net/99-meta-route` | OpenWrt 网络变化时触发路由修复 |

## 5. 路由器设置

### 数据面：DNS → fake-ip → TUN

```text
客户端 DNS → AGH :53
  直连域名 → 真实 IP → 主路由直接上网
  代理域名 → Mihomo DNS :253 → fake-ip
客户端访问 fake-ip → 主路由 → 安装设备 TUN → Mihomo → 代理节点
```

不同品牌菜单名称不同，需要完成这些设置：

1. **固定 IP**：为安装设备设置固定 LAN 地址。
2. **DHCP/DNS**：向客户端下发安装设备的 IP 作为 DNS，客户端默认网关仍是主路由。不是修改 WAN DNS；修改后让客户端重新联网/续租，避免额外公共 DNS 或浏览器安全 DNS 绕过 AGH。
3. **静态路由**：若安装在独立设备，主路由添加目标 `198.18.0.0/16`（掩码 `255.255.0.0`）、下一跳为安装设备 IP、接口为 LAN。安装在主路由上则无需这条手工路由，脚本维护本机 TUN 路由。
4. **端口与防火墙**：AGH 需独占 TCP/UDP 53；已有 DNS 服务应调整监听，保留 DHCP。允许客户端 DNS 请求、LAN 与 TUN 转发及 TUN 回送本机流量。安装器开启 IPv4 转发；容器需宿主机开放 TUN。

**DNS 和 fake-ip 路由缺一不可。** 安装器不会修改主路由的 DHCP、防火墙或手工静态路由；改 fake-ip 网段后应同步改主路由。

## 6. 下载代理与下载列表

脚本下载依次尝试：**下载所在机器的 Core 代理 → 填写的外部后备代理 → 直连**。某通道失败才尝试下一个；无需手工判断 Core 是否启动。

首次安装可填写外部代理；后续更新通常走目标机自身的 Core。SSH 安装下载发生在发起端，向导分别填写“发起端下载代理”和“目标机后备代理”；目标机的软件包由自己的软件源下载。包管理器使用自身代理配置。

除仓库文件外还下载下表资源；SSH 模式先在发起端下载项目资源再上传。安装位置相对于 `/etc/proxy`，版本和架构自动选择。

### 下载列表

| 内容 | 来源 / 文件 | 安装位置或用途 |
|---|---|---|
| 缺失系统依赖 | 各设备软件源；工具、CA 证书及按需定时任务工具 | 包管理器安装；依赖齐全时跳过 |
| 节点订阅 | 用户订阅地址，分别请求香港、日本、新加坡、台湾、美国 | `core/proxy/` 下 5 份 YAML |
| Mihomo 版本信息 | [GitHub Release API](https://api.github.com/repos/MetaCubeX/mihomo/releases/latest) | 临时 JSON，确定最新版 |
| Mihomo 程序 | [Mihomo Releases](https://github.com/MetaCubeX/mihomo/releases)，`mihomo-linux-<架构>-<版本>.gz` | `core/mihomo`；x86_64 用 `amd64-compatible` |
| metacubexd 面板 | [compressed-dist.tgz](https://github.com/MetaCubeX/metacubexd/releases/latest/download/compressed-dist.tgz) | `core/ui/` |
| AGH 程序 | [AGH Releases](https://github.com/AdguardTeam/AdGuardHome/releases)，`AdGuardHome_linux_<架构>.tar.gz` | `agh/AdGuardHome` |
| AdAway | [filter_2.txt](https://adguardteam.github.io/HostlistsRegistry/assets/filter_2.txt) | `agh/data/filters/1733109081.txt` |
| AdGuard DNS filter | [filter_1.txt](https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt) | `agh/data/filters/1733109082.txt` |
| WindowsSpyBlocker | [filter_23.txt](https://adguardteam.github.io/HostlistsRegistry/assets/filter_23.txt) | `agh/data/filters/1733109083.txt` |
| anti-AD | [filter_21.txt](https://adguardteam.github.io/HostlistsRegistry/assets/filter_21.txt) | `agh/data/filters/1733109085.txt` |
| 非中国顶级域名 | [tld-not-cn.txt](https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/tld-not-cn.txt) | `agh/download/notcn.txt`，生成上游规则 |
| GFW 域名 | [gfw.txt](https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/gfw.txt) | `agh/download/gfwlist.txt`，生成上游规则 |

## 7. 卸载

先把客户端 DNS 恢复到可用服务器，并撤销主路由上手工添加的 fake-ip 静态路由及相关防火墙改动。

### 脚本卸载（推荐）

以 root 执行，按提示选择是否删除文件并确认：

```sh
sh /etc/proxy/sh/uninstall.sh
```

自定义安装目录需显式指定，例如：

```sh
sh /opt/myproxy/sh/uninstall.sh --install-dir /opt/myproxy --purge
```

脚本清理项目服务、自启动、hotplug、定时任务及已记录的残留路由，按安装记录恢复转发设置；选择删除时清理程序、配置、运行数据和已空的安装目录。**不卸载系统软件包，不改其它任务。**

### 手工卸载

以 root 操作，只处理属于本安装目录的项目文件：

1. 用 `crontab -e` 删除本目录的 `MyProxy:update-scripts`、`MyProxy:update-configs` 任务；若自行添加了保活任务，也删除。
2. **systemd**：运行 `systemctl stop agh proxy_core`，删除 `/etc/systemd/system/` 中 `agh.service`、`proxy_core.service` 及其 `.wants/`、`.requires/` 自启动链接，再运行 `systemctl daemon-reload`。**OpenWrt**：分别执行 `/etc/init.d/agh stop`、`/etc/init.d/proxy_core stop`，再分别执行 `disable`；删除这两个 init.d 文件及 `/etc/hotplug.d/net/99-meta-route`，检查 `/etc/rc.d/` 中对应链接已清理。
3. 确认进程退出，检查 `ip route`。若本项目的 `198.18.0.0/16 dev utun` 仍残留，运行 `ip route del 198.18.0.0/16 dev utun`；修改过网段/接口时以 `core/.fake-ip-route` 记录为准。
4. 删除数据前，按 `sh/.install-state/forward/` 的 `before`、`runtime`、`existed` 恢复 IPv4 转发：systemd 配置在 `/etc/sysctl.d/99-zz-myproxy.conf`，OpenWrt 在 `/etc/sysctl.conf`。保留后续其它改动；无记录时不要猜测原值或直接关闭路由器转发。具体规则见 [ARCH](ARCH.md#93-卸载流程)。
5. 需要删除数据时，清理安装目录下的 `sh/`、`core/`、`agh/`，再删除空安装目录。保留系统软件包及其它文件。

技术细节见 [ARCH.md](ARCH.md)，待办见 [TODO.md](TODO.md)。
