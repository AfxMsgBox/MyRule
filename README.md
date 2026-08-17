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

启动后会进入**9 步交互式向导**：仓库分支、外部代理、节点订阅 URL、AGH 用户名、AGH 密码（bcrypt 哈希）、AGH 上游 DNS、是否立即启用服务、脚本更新间隔和配置更新间隔。重装时方括号显示当前值，回车保留。无 tty 时要求 `env.local.conf` 已具备必填项，默认启用服务，但不会交互安装 cron。

第 7 步**服务启动询问**：

- **Y（默认）**：把 `sh/etc/` 下的服务文件复制到 `/etc/init.d`（OpenWrt）或 `/etc/systemd/system`（Debian），并 `enable + start`。后续 `update-scripts.sh` 也会同步覆盖这些 `/etc` 副本。
- **n**：不动 `/etc`，服务文件留在 `$MP_INST_DIR/sh/etc/`。`inst.sh` 结尾会打印对应的手动安装命令（也可以以后重跑 `inst.sh` 选 Y）。

安装阶段会先渲染 `core/config.yaml`，再解析其 `proxy-providers` / `rule-providers` 的 `type`、`url` 和 `path`，把 Mihomo 首次启动所需的订阅与规则集全部预下载。随后按 `uname -m` 下载最新版 Mihomo、AdGuardHome 及 Web UI。最后渲染 `agh.yaml`，并把 `filters` 与 `whitelist_filters` 预下载到 `agh/data/filters/<id>.txt`。上述必需文件有任何一项失败，安装器都不会启动服务。

安装器还会开启 `net.ipv4.ip_forward`：systemd 系统持久化到较晚加载的 `/etc/sysctl.d/99-zz-myproxy.conf`，OpenWrt 持久化到 `/etc/sysctl.conf`，并读取 `/proc/sys/net/ipv4/ip_forward` 验证是否已经即时生效。LXC 等受限环境无法修改内核参数时会明确警告，但不会中断安装，需要在宿主机侧放行。

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
export MP_REPO_RAW_URL=https://raw.githubusercontent.com/AfxMsgBox/MyRule/refs/heads/claude/update-readme-overview-pU5D3
wget -O- "$MP_REPO_RAW_URL/sh/inst.sh" | sh -s -- /etc/proxy

# 通过 SSH SOCKS5 / 其它代理安装；HTTP 代理同样适用
# 同一个外部代理同时用于安装和以后的后备下载
export MP_REPO_RAW_URL=https://raw.githubusercontent.com/AfxMsgBox/MyRule/refs/heads/claude/update-readme-overview-pU5D3
export MP_PROXY=socks5h://192.168.2.250:7890
curl --fail --location --progress-bar --proxy "$MP_PROXY" "$MP_REPO_RAW_URL/sh/inst.sh" | sh -s -- /etc/proxy
```

inst.sh 自动识别 OpenWrt / systemd 并分发对应服务文件。第 2 步会先读取已有 `MP_PROXY`：未设置时只提供直连或手工输入；已设置时默认直接使用现有代理，也可改为直连或修改 URL。安装时，`MP_PROXY` 就是外部安装代理；Core 尚未可用时会自动落到该代理，再失败则试直连。全部文件就绪后，安装器先启动 Core，等待配置中的 API 可用，再启动 AGH。

在 systemd 系统上，安装器直接为原生 unit 建立 `multi-user.target.wants` 链接后启动服务，不调用 `systemctl enable`。这样即使系统残留同名 `/etc/init.d/agh`，也不会触发 Debian 的 SysV 兼容同步并导致启用失败。

日常下载的回退顺序为：`core/config.yaml` 派生的本机 Core 代理 → `MP_PROXY` 外部代理 → 强制直连。整批更新期间，正式 `core/config.yaml` 保持不变，新配置只写入 pending 文件，因此所有下载始终能使用正在运行的旧 Core 代理；如果任一必需下载失败，会丢弃 Core/AGH pending 配置并跳过重启。

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

- 纯 shell 语法，被 `env.conf` `source` 读取。每行 `KEY="value"`，值有空格 / 特殊字符必须加引号。
- 可覆盖下表中的本机参数；`core/` 与 `agh/` 路径固定从 `MP_INST_DIR` 派生，不单独配置。
- 优先级（高 → 低）：**系统环境变量 > env.local.conf > env.conf 默认值**
  - 临时调试用 `MP_FOO=xxx sh script.sh` 即可压过 env.local.conf。
- 重复运行 inst.sh 时下表中各项被 upsert（已存在则替换，不存在则追加），用户加的其它行不动。

**inst.sh 向导询问 + 写入**：

| 变量 | 默认 | 必填 | 说明 |
|---|---|---|---|
| `MP_REPO_RAW_URL` | `.../main` | | GitHub Raw 仓库根 URL；向导输入分支名自动拼成 `.../refs/heads/<branch>` |
| `MP_PROXY` | 空 | | 唯一的外部代理；安装时用于自举，日常更新时作为 Core 的后备，置空则跳过 |
| `MP_SUBSCRIBE_URL` | 空 | ✔ | 节点订阅 URL（`core/config.yaml` 的 `{MP_SUBSCRIBE_URL}` 引用） |
| `MP_AGH_USER_NAME` | 空 | ✔ | AGH Web UI 用户名 |
| `MP_AGH_PASSWORD` | 空 | ✔ | AGH Web UI 密码（**bcrypt 哈希**，生成方法见上节） |
| `MP_LOCAL_DNS` | `223.5.5.5 119.29.29.29` | | AGH 上游 DNS（空格分隔多个；置空读 `/etc/resolv.conf`） |
| `MP_INST_DIR` | 由 inst.sh 自动写入 | | 安装根目录，init.d / systemd 服务靠它定位 env.local.conf |

**示例**（最小化，单机 + 默认路径）：

```sh
MP_INST_DIR='/etc/proxy'
MP_REPO_RAW_URL='https://raw.githubusercontent.com/AfxMsgBox/MyRule/main'
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
| 下载全部文件（Core 配置/providers + AGH 配置/dns.conf/filters；AGH 配置只暂存） | `sh /etc/proxy/sh/update-all-configs.sh` |
| 下载全部文件 + 按 AGH 停止 → 替换 agh.yaml → Core 重启就绪 → AGH 启动切换 | `sh /etc/proxy/sh/update-all-configs-restart-services.sh` |
| 仅 AGH dns.conf | `sh /etc/proxy/sh/update-agh-config.sh` |
| 仅 core config.yaml（同时预下载其 HTTP providers） | `sh /etc/proxy/sh/update-core-config.sh` |
| 仅订阅与规则集（PUT mihomo providers） | `sh /etc/proxy/sh/update-proxy-rule.sh` |

单独执行 `update-core-config.sh` 不会同步或重启 AGH。如果新 Core 配置修改了代理端口、DNS 监听地址等 AGH 依赖字段，应执行 `update-all-configs-restart-services.sh` 完成整批更新和服务切换。

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

交互安装的第 8、9 步会依次询问“脚本更新”和“配置更新”的间隔天数，默认 3 天。输入 `n` 可单独跳过某一项。安装器会在 root crontab 中维护以下两个带 marker 的任务：先在 03:00 更新脚本，再于 03:05 更新配置并重启服务；重装不会重复追加：

```cron
0 3 */N * * sh /etc/proxy/sh/update-scripts.sh # MyProxy:update-scripts
5 3 */N * * sh /etc/proxy/sh/update-all-configs-restart-services.sh # MyProxy:update-configs
```

其中 `N` 是向导输入的天数。OpenWrt 写入至少一项任务后，安装器还会启用并重启 cron 服务。下面两项不会由安装器自动添加，需要时再手工配置，不会与上述任务重复：

```cron
*/5 * * * * sh /etc/proxy/sh/keeplive.sh
0 5 1 * * sh /etc/proxy/sh/update-bin.sh && systemctl restart proxy_core agh
```

---

## 仓库结构

```
sh/             脚本与模板
  inst.sh                      首次安装
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
