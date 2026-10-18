# MyRule

在 **OpenWrt** 或 **Debian/Ubuntu（systemd）** 上安装 AdGuardHome 和 Mihomo，提供 DNS 过滤与透明代理。默认安装目录为 `/etc/proxy`。

## 安装前准备

- 使用 root，准备好 `curl`、`jq`；缺少依赖时安装器会提示并退出。
- 准备节点订阅 URL、AdGuardHome 管理员用户名和密码的 **bcrypt 哈希**。
- 首次安装无法访问下载源时，准备一个 HTTP 或 SOCKS 代理地址。

如果系统已有 `htpasswd`，可交互生成密码哈希：

```sh
htpasswd -nB -C 10 admin
```

按提示输入密码，复制输出中 `admin:` 后面的整段哈希；安装时填写哈希，登录时使用原密码。Debian/Ubuntu 可通过 `apt install apache2-utils` 安装此命令。

## 安装

### 交互安装

```sh
curl -fL -o /tmp/myrule-inst.sh https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/inst.sh
sh /tmp/myrule-inst.sh
```

无参数运行即进入向导，安装到 `/etc/proxy`。按提示填写代理、分支、订阅和管理员信息，并选择是否启动服务、设置自动更新。在线分支按编号选择，默认 `main`。

下载脚本本身也需要代理时，在上面的 curl 命令中添加 `--proxy 'socks5h://127.0.0.1:1080'`；运行安装器后仍需按提示填写代理。

### 静默安装

有任意参数即进入静默模式，以下三个参数每次都必须提供；替换示例中的订阅和哈希：

```sh
sh /tmp/myrule-inst.sh \
  --subscribe-url 'https://example.com/subscription' \
  --agh-user admin \
  --agh-password '$2b$10$你的完整bcrypt哈希'
```

静默安装成功后自动启用服务，重装时重启服务；不会修改自动更新任务。支持 `--参数 值` 和 `--参数=值`，使用 `--help` 查看帮助。

| 参数 | 用途 / 默认值 |
|---|---|
| `--subscribe-url URL` | 必填，HTTP/HTTPS 节点订阅地址 |
| `--agh-user USER` | 必填，管理员用户名 |
| `--agh-password HASH` | 必填，bcrypt 哈希，用单引号包裹 |
| `--install-dir DIR` | 安装目录，默认 `/etc/proxy`；路径不要包含空格或中文 |
| `--source-dir DIR` | 本地仓库根目录，省略则从 GitHub 下载 |
| `--branch NAME` | GitHub 分支名，省略或为空使用 `main` |
| `--dns 'DNS1 DNS2'` | 默认 `223.5.5.5 119.29.29.29`；传 `--dns ''` 使用系统 DNS |
| `--proxy URL` | 外部后备代理，省略则不使用外部代理；已有 Core 代理仍会优先尝试 |

可在上面的命令末尾添加 `--branch dev --proxy 'socks5h://127.0.0.1:1080'` 等可选参数。静默模式不会沿用旧配置补齐参数；重装时不传 `--proxy` 会清空原外部代理。

### 从本地仓库安装

下载仓库 ZIP 并解压，然后执行：

```sh
cd /path/to/MyRule-main
sh sh/inst.sh
```

在向导中选择“本地仓库目录”，填写解压目录和**后续 GitHub 更新分支**。源目录与安装目录必须分开，安装目录不能放在源目录里面。

也可以静默安装：

```sh
sh /path/to/MyRule-main/sh/inst.sh \
  --source-dir /path/to/MyRule-main --branch main \
  --subscribe-url 'https://example.com/subscription' \
  --agh-user admin --agh-password '$2b$10$你的完整bcrypt哈希'
```

**本地安装仍需联网**下载程序、面板、订阅及外部规则，需要代理时添加 `--proxy`。以后更新从指定的 GitHub 分支获取仓库文件，本地源目录可在安装后删除。[完整下载清单](#下载列表)。

### 下载代理与重装

安装和更新依次尝试：**已有 Core 代理 → 指定的外部代理 → 直连**。首次安装可指定外部代理；之后通常可使用运行中的 Core。外部代理支持 `http://`、`https://`、`socks5://`、`socks5h://`。

交互重装选择“不启动服务”时，新配置不会立即启用，但脚本和程序等文件可能已经更新。以后可重新运行安装器并选择启动，或按安装器打印的命令操作。

### 下载列表

除本仓库文件外，在线安装和本地安装都会下载以下内容。安装位置相对于安装目录（默认 `/etc/proxy`）；`<版本>` 为最新发行版本，`<架构>` 按设备 CPU 自动选择。

| 内容 / 用途 | 下载来源 | 下载文件或响应 | 安装位置 / 处理方式 |
|---|---|---|---|
| 节点订阅（香港、日本、新加坡、台湾、美国） | 用户提供的 `--subscribe-url` / `MP_SUBSCRIBE_URL`，由 Core 模板追加地区筛选等查询参数 | 分别请求 5 份节点 YAML | `core/proxy/HongKong.yaml`、`Japan.yaml`、`Singapore.yaml`、`TaiWan.yaml`、`USA.yaml`（均在 `core/proxy/` 下） |
| Mihomo 最新版本信息 | `https://api.github.com/repos/MetaCubeX/mihomo/releases/latest` | Release JSON，读取 `tag_name` | 临时文件，用完删除 |
| Mihomo 代理内核 | `https://github.com/MetaCubeX/mihomo/releases/download/<版本>/mihomo-linux-<架构>-<版本>.gz` | `mihomo-linux-<架构>-<版本>.gz` | 解压为 `core/mihomo` |
| metacubexd Web 面板 | `https://github.com/MetaCubeX/metacubexd/releases/latest/download/compressed-dist.tgz` | `compressed-dist.tgz` | 解压到 Core 的 `external-ui` 指定目录，当前为 `core/ui/` |
| AdGuardHome 程序 | `https://github.com/AdguardTeam/AdGuardHome/releases/latest/download/AdGuardHome_linux_<架构>.tar.gz` | `AdGuardHome_linux_<架构>.tar.gz` | 提取程序到 `agh/AdGuardHome` |
| AdAway Default Blocklist | `https://adguardteam.github.io/HostlistsRegistry/assets/filter_2.txt` | `filter_2.txt` | `agh/data/filters/1733109081.txt` |
| AdGuard DNS filter | `https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt` | `filter_1.txt` | `agh/data/filters/1733109082.txt` |
| WindowsSpyBlocker - Hosts spy rules | `https://adguardteam.github.io/HostlistsRegistry/assets/filter_23.txt` | `filter_23.txt` | `agh/data/filters/1733109083.txt` |
| CHN: anti-AD | `https://adguardteam.github.io/HostlistsRegistry/assets/filter_21.txt` | `filter_21.txt` | `agh/data/filters/1733109085.txt` |
| 非中国顶级域名列表 | `https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/tld-not-cn.txt` | `tld-not-cn.txt` | 保存为 `agh/download/notcn.txt`，转换为 AGH 上游规则时剔除 `.bj` |
| GFW 域名列表 | `https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/gfw.txt` | Clash payload 格式的 `gfw.txt` | 保存为 `agh/download/gfwlist.txt`，转换为 AGH 上游规则 |

## 安装后使用

当前默认配置的访问地址如下；修改过端口时以实际配置为准：

| 用途 | 地址 |
|---|---|
| AdGuardHome 管理页面 | `http://设备IP:180`，使用安装时设置的用户名和原密码登录 |
| Mihomo 面板 | `http://设备IP:3721/ui/` |
| DNS 服务 | `设备IP:53` |

客户端的 DNS 应指向这台设备；使用透明代理时，还需让客户端流量经过该设备，并允许相应的防火墙转发。安装器会开启 IPv4 转发；LXC 等环境提示无法开启时，需要在宿主机处理。

## 更新与查看日志

以下命令按 `/etc/proxy` 安装目录编写；安装在其它位置时替换路径。

| 操作 | 命令 |
|---|---|
| 更新脚本 | `sh /etc/proxy/sh/update-scripts.sh` |
| 更新配置、订阅和规则并重启服务 | `sh /etc/proxy/sh/update-all-configs-restart-services.sh` |
| 下载最新版 Mihomo、AdGuardHome 和面板 | `sh /etc/proxy/sh/update-bin.sh` |
| 查看 OpenWrt 日志 | `logread -e MyProxy -f` |
| 查看 Debian/Ubuntu 日志 | `journalctl -t MyProxy -f` |

升级程序后需要重启服务才能生效：

```sh
# Debian/Ubuntu
systemctl restart proxy_core agh

# OpenWrt
/etc/init.d/proxy_core restart && /etc/init.d/agh restart
```

仅在更新成功后执行重启。查看服务状态可用 `systemctl status proxy_core agh`（Debian/Ubuntu），或分别运行 `/etc/init.d/proxy_core status`、`/etc/init.d/agh status`（OpenWrt）。

交互安装可设置自动更新：脚本在 03:00、配置在 03:05 执行。默认日期步长为 3，即每月 1、4、7……日，输入 `n` 跳过设置，已有任务不会删除。用 `crontab -l` 查看、`crontab -e` 修改。静默安装不设置这些任务。

## 修改配置

### env.local.conf

本机参数保存在 `/etc/proxy/sh/env.local.conf`，安装器自动生成；需要时可手动编辑。字符串使用单引号包裹，不要把含订阅或密码的文件上传到仓库。

| 变量 | 用途 |
|---|---|
| `MP_SUBSCRIBE_URL` | 节点订阅 URL |
| `MP_AGH_USER_NAME` | 管理员用户名 |
| `MP_AGH_PASSWORD` | 管理员密码的 bcrypt 哈希 |
| `MP_REPO_BRANCH` | 后续更新分支，默认 `main` |
| `MP_PROXY` | 外部后备代理，空值表示不使用 |
| `MP_LOCAL_DNS` | 上游 DNS，多个地址以空格分隔；空值使用系统 DNS |
| `MP_INST_DIR` | 安装目录，由安装器写入，不要通过改此值迁移安装 |

修改后运行配置更新命令使其生效：

```sh
sh /etc/proxy/sh/update-all-configs-restart-services.sh
```

分流域名在仓库 `domain/*.txt` 中维护，提交到所用分支后再更新。**完整配置更新会覆盖在 AdGuardHome 页面中修改的配置**；需要长期保留的修改应维护到仓库模板中。

## 卸载

```sh
# 移除服务和安装器创建的自动更新任务，保留文件与数据
sh /etc/proxy/sh/uninstall.sh

# 同时删除安装目录中的 sh/、core/、agh/，包括配置和运行数据
sh /etc/proxy/sh/uninstall.sh --purge
```

默认询问确认，回车取消。安装在其它目录时，必须显式指定绝对路径：

```sh
sh /opt/myproxy/sh/uninstall.sh --install-dir /opt/myproxy --purge
```

自动化执行可加 `--yes` 跳过询问。卸载保留 IPv4 转发设置和手工添加的定时任务；不要与安装或更新同时运行。

实现细节和高级维护操作见 [ARCH.md](ARCH.md)，未完成事项见 [TODO.md](TODO.md)。
