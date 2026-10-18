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

安装前需要 root 权限，并已安装 `curl`、`jq`。缺少 jq 时安装器会提示安装命令并退出，不自动安装依赖。

- **没有参数**：进入交互安装，目录固定为 `/etc/proxy`；没有交互终端则报错退出。
- **有任意参数**：进入静默安装，即使连接了终端也不询问。`--help` 单独使用时仅显示帮助。
- 使用命名参数，不再支持位置参数。参数解析和校验完成后才写入安装配置或修改系统。

交互向导依次询问：外部后备代理、仓库来源及更新分支、节点订阅 URL、AGH 用户名、AGH 密码（bcrypt 哈希）、AGH 上游 DNS、是否立即启用服务、脚本更新和配置更新的每月日期步长。订阅、密码和代理 URL 输入不回显；重装时可回车保留已有凭据。外部代理默认不使用，需要明确选择沿用或输入。

在线安装的分支列表从 GitHub 分页获取，完整加载后按编号选择，回车使用 `main`。获取失败时只能重试或退出，不使用残缺列表。静默安装直接使用指定分支，不请求分支列表。

### 静默参数

支持 `--参数 值` 和 `--参数=值`，未知、重复、缺值或无效参数会报错。

| 参数 | 默认值 / 要求 |
|---|---|
| `--subscribe-url URL` | 必填，非空 HTTP/HTTPS 节点订阅地址 |
| `--agh-user USER` | 必填，非空 AGH 用户名 |
| `--agh-password HASH` | 必填，bcrypt 哈希，用单引号包裹 |
| `--install-dir DIR` | `/etc/proxy`；支持相对路径；只允许字母、数字、下划线、点、斜杠和连字符 |
| `--source-dir DIR` | 可选，解压后的本地仓库根目录；不传则从 GitHub 下载仓库文件 |
| `--branch NAME` | 省略或空值为 `main`；填写分支名，支持 `feature/name`，不接受完整 URL |
| `--dns 'DNS1 DNS2'` | `223.5.5.5 119.29.29.29`；显式空值读取 `/etc/resolv.conf` |
| `--proxy URL` | 省略或空值表示不使用外部代理，仍会尝试现有 Core 代理 |

静默安装的上述参数完全由本次命令和默认值决定，不从环境变量或旧配置补齐；三个必填参数每次都需要提供。安装成功后自动启用服务，重装会重启服务，**不创建、修改或删除 cron 任务**。下载全部通道失败时直接退出，不询问重试。

### 服务与配置切换

第 7 步**服务启动询问**：

- **Y（默认）**：把 `sh/etc/` 下的服务文件复制到 `/etc/init.d`（OpenWrt）或 `/etc/systemd/system`（Debian）。重装时先停止 AGH 再切换配置，启用并重启 Core，等待 API 就绪后启用并重启 AGH；首次安装直接提交配置并依次启动服务。后续 `update-scripts.sh` 也会同步覆盖这些 `/etc` 副本。
- **n**：不安装或启用服务文件，服务文件留在 `$MP_INST_DIR/sh/etc/`。首次安装将配置写为正式文件；重装保留原 Core、AGH 主配置和 dns.conf，将新版本保留为三个 `.pending` 文件。安装器会打印手动应用命令，也可重跑 `inst.sh` 选 Y。前面步骤已经写入 `/etc` 下的 IPv4 转发配置。

安装阶段会先渲染 `core/config.yaml.pending`，再解析其 `proxy-providers` / `rule-providers` 的 `type`、`url` 和 `path`，把 Mihomo 首次启动所需的订阅与规则集全部预下载。随后按 `uname -m` 下载最新版 Mihomo、AdGuardHome 及 Web UI，UI 目录按 pending Core 配置确定。最后生成 `agh.yaml.pending`、`dns.conf.pending`，并把 `filters` 与 `whitelist_filters` 预下载到 `agh/data/filters/<id>.txt`。上述必需步骤有任何一项失败，安装器都不会切换配置或重启服务。

重装期间原正式配置保持不变，下载仍能使用旧 Core 代理；但本机参数、脚本、二进制、UI 和 provider/filter 资源会在准备阶段更新。因此，选择 n 仅推迟配置和服务切换，不代表整次安装完全没有落盘修改。

安装器还会开启 `net.ipv4.ip_forward`：systemd 系统持久化到较晚加载的 `/etc/sysctl.d/99-zz-myproxy.conf`，OpenWrt 持久化到 `/etc/sysctl.conf`，并读取 `/proc/sys/net/ipv4/ip_forward` 验证是否已经即时生效。LXC 等受限环境无法修改内核参数时会明确警告，但不会中断安装，需要在宿主机侧放行。

### 一键安装

```sh
# 下载后进入交互安装，默认安装到 /etc/proxy
curl -fL -o /tmp/myrule-inst.sh https://raw.githubusercontent.com/AfxMsgBox/MyRule/main/sh/inst.sh
sh /tmp/myrule-inst.sh

# 静默安装：只提供三个必填参数，其余使用默认值
# 将订阅地址和 bcrypt 哈希替换为自己的值
sh /tmp/myrule-inst.sh \
  --subscribe-url 'https://example.com/subscription' \
  --agh-user admin \
  --agh-password '$2b$10$你的完整bcrypt哈希'

# 指定目录、分支、外部后备代理；DNS 空值表示读取系统 DNS
sh /tmp/myrule-inst.sh \
  --install-dir /etc/proxy --branch 'feature/dev' --dns '' \
  --proxy 'socks5h://127.0.0.1:1080' \
  --subscribe-url 'https://example.com/subscription' \
  --agh-user admin --agh-password '$2b$10$你的完整bcrypt哈希'
```

下载 `inst.sh` 本身发生在安装器运行之前。若首次下载也需要代理，请在上面的 curl 命令增加 `--proxy '代理URL'`；进入安装器后再选择外部代理，或通过 `--proxy` 显式传入。

安装器自动识别 OpenWrt / systemd。终端中以颜色区分阶段、执行、成功和失败；设置 `NO_COLOR=1`、`TERM=dumb` 或重定向输出时使用纯文本，系统日志始终不带颜色。输出不展示密码、代理凭据和完整订阅 URL。

### 从本地仓库安装

从 GitHub 下载仓库 ZIP 并解压，目录中应包含 `sh/`、`core/`、`agh/`、`domain/`。源目录与安装目录分开，安装目录不能位于源目录内部。

```sh
cd /path/to/MyRule-main
sh sh/inst.sh
```

交互向导第 1 步照常设置外部代理，第 2 步选择“本地仓库目录”，输入解压目录（回车使用当前目录）。本地模式不获取远端分支列表；随后填写的分支名仅用于配置中的后续在线更新地址，默认 `main`。安装内容以本地文件为准，脚本不会猜测 ZIP 来自哪个分支。

静默安装使用 `--source-dir`；三个必填参数仍需提供：

```sh
sh /path/to/MyRule-main/sh/inst.sh \
  --source-dir /path/to/MyRule-main \
  --subscribe-url 'https://example.com/subscription' \
  --agh-user admin --agh-password '$2b$10$你的完整bcrypt哈希' \
  --proxy 'socks5h://127.0.0.1:1080'
```

本地读取包括仓库脚本、服务模板、Core/AGH 配置模板及仓库域名规则。必需文件缺失会报错，不回退下载远端副本。源目录中的 `sh/env.local.conf` 不会被复制。

**本地仓库安装仍然需要网络**：Mihomo、AdGuardHome、Web 面板、节点订阅、GFW 等外部规则及 AGH 过滤器仍按下述代理顺序下载；因此 `--proxy` 依然有效，curl 和 jq 仍为必需依赖。

本地源目录只用于本次安装，不保存到 `env.local.conf`。以后单独运行更新脚本，仍从 `MP_REPO_BRANCH` 指定的在线分支更新；本地源目录可以在安装完成后移走。

### 下载代理

需要联网的安装下载、分支列表获取、自举下载及日常更新采用相同顺序：

1. 从当前正式 `core/config.yaml` 读取端口，尝试本机 Core 代理。
2. 失败后尝试显式配置的 `MP_PROXY` 外部后备代理；未配置则跳过。
3. 最后尝试强制直连。

不提前检查 Core 进程、API 或测试网站，由实际文件下载是否成功决定回退。Core 端口依次取有效的 `mixed-port`、`port`、`socks-port`，没有配置时直接进入下一通道；不使用固定端口猜测。下载显式指定代理或直连，忽略系统 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY`、`NO_PROXY` 和用户 curl 配置的影响。

因此，首次安装可提供外部代理；之后即使不指定外部代理，已有 Core 可用时仍优先通过 Core 下载。配置中的外部代理会保留为日常更新的后备；重新静默安装时不传 `--proxy` 会清空旧外部代理。交互安装及日常手动更新在整轮失败且有终端时可重试；静默安装和无终端更新直接失败。

在 systemd 系统上，安装器直接为原生 unit 建立 `multi-user.target.wants` 链接后启动服务，不调用 `systemctl enable`。这样即使系统残留同名 `/etc/init.d/agh`，也不会触发 Debian 的 SysV 兼容同步并导致启用失败。

日常下载的回退顺序为：`core/config.yaml` 派生的本机 Core 代理 → `MP_PROXY` 外部代理 → 强制直连。在完整配置更新的下载阶段，正式 `core/config.yaml` 保持不变，下载优先使用旧配置对应的 Core 代理；如果任一必需下载失败，会丢弃 Core/AGH pending 配置并跳过重启。所有下载成功后，`update-all-configs.sh` 会写入正式 Core 配置和 dns.conf，只有 AGH 主配置继续暂存。

`agh/agh.yaml` 与 Core 配置一样以仓库模板为准。日常更新先下载、渲染并暂存为 `agh.yaml.pending`，同时预下载模板中的过滤器；只有所有下载成功且 AGH 已停止后，重启脚本才会用它完整替换正式配置。因此，通过 AGH Web UI 修改的用户、客户端、DHCP、过滤器等运行期配置会在下一次完整更新时被仓库模板覆盖，应统一在仓库模板中维护。

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

- 纯 shell 语法，被 `env.conf` `source` 读取。推荐每行 `KEY='value'`，使 `$`、反斜杠等保持原样。bcrypt 哈希必须使用单引号，双引号内的 `$` 仍会被 shell 展开。
- 值内含单引号时，用 `KEY='前半'\''后半'` 表示；安装向导会自动进行该转义。
- 可覆盖下表中的本机参数；`core/` 与 `agh/` 路径固定从 `MP_INST_DIR` 派生，不单独配置。
- 日常更新的优先级（高 → 低）：**系统环境变量 > env.local.conf > env.conf 默认值**（安装器的静默参数规则见上文）
  - 临时调试用 `MP_FOO=xxx sh script.sh` 即可压过 env.local.conf。
- 重复运行 inst.sh 时下表中各项被 upsert（已存在则替换，不存在则追加），用户加的其它行不动。

**inst.sh 向导询问 + 写入**：

| 变量 | 默认 | 必填 | 说明 |
|---|---|---|---|
| `MP_REPO_BRANCH` | `main` | | 仓库分支名；空值也表示 main，仓库固定为 AfxMsgBox/MyRule |
| `MP_PROXY` | 空 | | 唯一的外部后备代理；安装和更新都先尝试 Core，置空仅跳过外部代理 |
| `MP_SUBSCRIBE_URL` | 空 | ✔ | 节点订阅 URL（`core/config.yaml` 的 `{MP_SUBSCRIBE_URL}` 引用） |
| `MP_AGH_USER_NAME` | 空 | ✔ | AGH Web UI 用户名 |
| `MP_AGH_PASSWORD` | 空 | ✔ | AGH Web UI 密码（**bcrypt 哈希**，生成方法见上节） |
| `MP_LOCAL_DNS` | `223.5.5.5 119.29.29.29` | | AGH 上游 DNS（空格分隔多个；置空读 `/etc/resolv.conf`） |
| `MP_INST_DIR` | 由 inst.sh 自动写入 | | 安装根目录，init.d / systemd 服务靠它定位 env.local.conf |

`MP_LOCAL_DNS` 只有在未设置时才使用默认值。明确设置 `MP_LOCAL_DNS=''` 会读取 `/etc/resolv.conf`，交互安装保留这一含义；静默安装需显式传 `--dns ''`；向导第 6 步回车保留当前值，输入 `-` 可清空。

`MP_REPO_RAW_URL` 不再是可配置参数，旧值不会迁移为分支名；未配置 `MP_REPO_BRANCH` 时使用 `main`。重装保存本机配置时会删除旧 URL 项。内部下载地址由分支名统一生成。

**示例**（最小化，单机 + 默认路径）：

```sh
MP_INST_DIR='/etc/proxy'
MP_REPO_BRANCH='main'
MP_PROXY='socks5h://192.168.1.10:1080'
MP_SUBSCRIBE_URL='https://api.subcsub.com/sub?target=clash&url=<URL-encoded>'
MP_AGH_USER_NAME='admin'
MP_AGH_PASSWORD='$2a$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy'
MP_LOCAL_DNS='223.5.5.5 119.29.29.29'
```

`MP_PROXY` 支持 `http://`、`https://`、`socks5://` 和 `socks5h://`。名称不限定代理协议，也不再另设安装/后备代理变量。

### Core 配置是唯一运行基础

不再为 Core 的端口、地址、TUN 或 fake-ip 另设全局变量。每次安装或更新 `core/config.yaml` 后，各脚本都直接解析新配置：

| Core 字段 | 使用处 |
|---|---|
| `mixed-port`（其次 `port` / `socks-port`） | 日常下载首选代理、AGH `http_proxy`、保活检查 |
| `external-controller` + `secret` | Core API 就绪检查、provider API 刷新 |
| `dns.listen` | AGH 域名分流的上游地址 |
| `tun.device` + `dns.fake-ip-range` | fake-ip 路由生成 |
| `external-ui` | Web UI 安装目录 |
| `proxy-providers` / `rule-providers` | provider 名称、URL 和本地路径 |

DNS 与 fake-ip 是本方案的必需配置；脚本读取 `dns.listen` 和 `dns.fake-ip-range`，不再对 `dns.enable` / `dns.enhanced-mode` 做多余判断。如果必需字段缺失或无效，配置更新会直接失败，不使用脚本内的隐藏默认值。

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
| 下载并写入 Core 配置、dns.conf、providers、filters；仅 AGH 主配置暂存，不重启服务 | `sh /etc/proxy/sh/update-all-configs.sh` |
| 下载全部文件 + 按 AGH 停止 → 替换 agh.yaml → Core 重启就绪 → AGH 启动切换 | `sh /etc/proxy/sh/update-all-configs-restart-services.sh` |
| 仅 AGH dns.conf | `sh /etc/proxy/sh/update-agh-config.sh` |
| 仅 core config.yaml（同时预下载其 HTTP providers） | `sh /etc/proxy/sh/update-core-config.sh` |
| 仅订阅与规则集（PUT mihomo providers） | `sh /etc/proxy/sh/update-proxy-rule.sh` |

单独执行 `update-core-config.sh` 不会同步或重启 AGH。如果新 Core 配置修改了代理端口、DNS 监听地址等 AGH 依赖字段，应执行 `update-all-configs-restart-services.sh` 完成整批更新和服务切换。

日常运维推荐使用 `update-all-configs-restart-services.sh`。单独运行 `update-all-configs.sh` 后，磁盘上的 Core 配置与运行进程可能不同；例如修改代理端口后，后续下载会尝试新端口，而运行中的 Core 仍监听旧端口，只能回退到外部代理或直连。它也不是整批回滚事务：已写入的资源文件不会因后续步骤失败而自动恢复。

新增 / 修改分流规则：编辑 `domain/*.txt` 并提交到 `MP_REPO_BRANCH` 指定的仓库分支，下次 cron 触发或手动更新即可同步。AGH 的域名分流与 Core 的 GPT 规则使用同一仓库分支。

修改 `external-ui` 后，完整配置更新不会迁移或下载面板文件；还需运行 `update-bin.sh` 将 UI 安装到新目录，该命令也会更新两个二进制。可按以下顺序完成下载和切换（任一步失败都不要继续）：

```sh
MP_INST_DIR='/etc/proxy'
export MP_INST_DIR
. "$MP_INST_DIR/sh/common.sh"
sh "$MP_INST_DIR/sh/update-all-configs.sh" &&
sh "$MP_INST_DIR/sh/update-bin.sh" &&
mp_activate_configs restart
```

这个流程在配置落盘后下载二进制/UI；若同时改了代理端口，需确保外部代理或直连可用。

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
| 清 fake-ip 缓存 | 先按下方示例加载 `common.sh`，再调用 Core API |

```sh
# 按实际安装路径设置；不要依赖交互 shell 的 $0 反推路径
MP_INST_DIR=/etc/proxy
export MP_INST_DIR
. "$MP_INST_DIR/sh/common.sh"
core_api=$(mp_core_api_url) || exit 1
core_secret=$(mp_core_value "" secret 2>/dev/null || :)
if [ -n "$core_secret" ]; then
    curl --noproxy '*' -H "Authorization: Bearer $core_secret" \
        -X POST "$core_api/cache/fakeip/flush"
else
    curl --noproxy '*' -X POST "$core_api/cache/fakeip/flush"
fi
```

### 定时任务

交互安装的第 8、9 步会依次询问“脚本更新”和“配置更新”的每月日期步长，默认 3。输入 `n` 可单独跳过某一项的写入（已有任务不会删除）。安装器会在 root crontab 中维护以下两个带 marker 的任务：03:00 触发脚本更新，03:05 触发配置更新并重启服务；重装不会重复追加。这是两个独立任务，时间错开不保证前一个任务已完成：

```cron
0 3 */N * * sh /etc/proxy/sh/update-scripts.sh # MyProxy:update-scripts
5 3 */N * * sh /etc/proxy/sh/update-all-configs-restart-services.sh # MyProxy:update-configs
```

其中 `N` 是向导输入的日期步长。例如 `N=3` 表示每月 1、4、7……日执行，每月重新从 1 日计算，跨月不是固定间隔 3 天。OpenWrt 写入至少一项任务后，安装器还会启用并重启 cron 服务。下面两项不会由安装器自动添加，需要时再手工配置，不会与上述任务重复：

```cron
*/5 * * * * sh /etc/proxy/sh/keeplive.sh
0 5 1 * * sh /etc/proxy/sh/update-bin.sh && systemctl restart proxy_core agh
```

---

## 卸载

使用 root 执行，支持 OpenWrt 与 systemd：

```sh
# 移除服务、自启动、hotplug 和安装器创建的定时任务，保留安装文件
sh /etc/proxy/sh/uninstall.sh

# 同时删除 sh/、core/、agh/，包括配置、凭据、订阅缓存及运行数据
sh /etc/proxy/sh/uninstall.sh --purge

# 指定安装目录并自动确认；也可从下载的仓库运行卸载脚本
sh /path/to/MyRule/sh/uninstall.sh --install-dir /opt/myproxy --purge --yes
```

`--install-dir` 默认为 `/etc/proxy`，需使用绝对路径；安装在其它位置时必须显式指定。默认先展示卸载范围并询问确认，回车取消；没有终端时必须传 `--yes`。`--yes` 只跳过询问，仍进行归属和路径检查。

卸载先移除目标安装的两条自动更新 cron，再依次停止 AGH、Core，清理已确认归属的服务文件、自启动链接和 OpenWrt hotplug。systemd 随后重新加载配置。停止服务失败或发现目标二进制仍在运行时，不删除服务文件或安装数据；后续清理失败会报错，不打印成功。已完成的步骤不会自动回滚，例如停止失败前自动更新任务可能已被移除。

默认保留整个安装目录。`--purge` 仅删除其中的 `sh/`、`core/`、`agh/`，保留安装根目录和其它文件；删除前必须能从 `sh/env.local.conf` 确认安装路径。系统目录、作为符号链接的三个子目录以及内部挂载点均不允许清理。同名服务属于其它安装、systemd 存在额外覆盖配置时会中止，需核实后再处理。

IPv4 转发设置始终保留：安装器没有记录原值，卸载时不能可靠恢复，也不会主动关闭系统转发。手工添加的 cron、其它安装目录的任务和系统日志保留；脚本只移除带 `MyProxy:update-scripts` / `MyProxy:update-configs` 标记且命令路径匹配的任务。卸载期间不要同时运行安装或更新脚本，已经运行的更新任务不会被自动终止。

---

## 仓库结构

```
sh/             脚本与模板
  inst.sh                      首次安装
  uninstall.sh                 卸载服务，可选清理安装数据
  update-scripts.sh            刷新所有脚本（含 env.conf / common.sh / sh/etc/* / 自身）
  update-bin.sh                刷新 mihomo / AdGuardHome 二进制
  update-all-configs.sh        刷新 Core 配置/providers，并暂存 AGH 配置、刷新 dns.conf/filters
  update-all-configs-restart-services.sh  上面 + 按依赖顺序切换服务
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

## 开发验证

架构与维护约束见 `ARCH.md`，待办和验证限制见 `TODO.md`。单元测试使用 Python 3 标准库、POSIX shell 和 jq，无额外 Python 依赖：

```sh
python3 -B -m unittest discover -s tests -v
```

测试使用临时目录及模拟下载、服务命令，不联网、不修改系统服务。真实 OpenWrt/systemd 部署仍需另行验证。
