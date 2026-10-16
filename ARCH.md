# MyRule 架构说明

本文面向后续维护者和代码代理，用于说明项目的真实运行结构、数据流、配置权威关系和修改约束。用户安装与运维命令以 `README.md` 为准；修改代码前应先阅读本文及涉及的具体脚本。

## 1. 项目目标

MyRule 在 OpenWrt 或 systemd Linux 上组合 AdGuardHome（下称 AGH）与 Mihomo（代码中称 Core），实现基于 DNS 的透明代理分流：

```text
客户端 DNS 查询
    │
    ▼
AGH :53
    ├─ 直连域名 ──► 公共/本地上游 DNS ──► 真实 IP
    └─ 代理域名 ──► Core DNS ──► fake-ip
                                   │
客户端访问 fake-ip                 │
    └─ 系统路由 ──► Mihomo TUN ────┘──► 代理节点
```

核心分工：

- AGH 是客户端 DNS 入口，并根据 `agh/dns.conf` 决定域名使用直连 DNS 还是 Core DNS。
- Core DNS 为代理域名分配 fake-ip。
- 系统把整个 fake-ip 网段路由到 Core 的 TUN 设备。
- Mihomo 的规则与代理组决定进入 TUN 后使用哪个节点。
- 本项目不修改宿主机自身的 `/etc/resolv.conf`；宿主机 DNS 不依赖 AGH。

## 2. 目录与状态归属

```text
README.md                     用户文档
ARCH.md                       内部架构与维护约束

core/config.yaml              Mihomo 配置模板
agh/agh.yaml                  AGH 配置模板
agh/myupstream.txt            AGH 固定格式的自定义上游片段
domain/*.txt                  Clash payload 格式的域名清单

sh/inst.sh                    安装和重装入口
sh/env.conf                   全局默认值、环境加载及派生路径
sh/common.sh                  公共解析、下载、渲染、服务控制函数
sh/update-*.sh                各类更新入口
sh/setup-fake-ip-route.sh     fake-ip 路由修正
sh/keeplive.sh                Core 本机代理保活
sh/etc/                       OpenWrt/systemd 服务文件模板
```

安装后的根目录由 `MP_INST_DIR` 指定，固定包含：

```text
$MP_INST_DIR/
├── sh/                       可更新的脚本及服务文件副本
│   └── env.local.conf        本机私有配置，不入库
├── core/                     Mihomo home、二进制和运行数据
└── agh/                      AGH 工作目录、二进制和运行数据
```

重要状态分类：

| 类型 | 权威来源 | 运行时目标 |
|---|---|---|
| 脚本 | 仓库 `sh/` | `$MP_INST_DIR/sh/`，必要时同步 `/etc` 服务文件 |
| Core 配置 | 仓库 `core/config.yaml` 模板 | `$MP_INST_DIR/core/config.yaml` |
| AGH 配置 | 仓库 `agh/agh.yaml` 模板 | `$MP_INST_DIR/agh/agh.yaml` |
| 本机参数 | `env.local.conf` 或调用方环境 | 模板渲染及脚本运行环境 |
| Core providers | Core 模板中的 `url` 与 `path` | `$MP_CORE_DIR/<path>` |
| AGH filters | AGH 模板中的 `filters`/`whitelist_filters` | `$MP_AGH_DIR/data/filters/<id>.txt` |
| AGH 域名上游 | 仓库规则及外部规则 | `$MP_AGH_DIR/dns.conf` |
| 二进制/UI | 上游 GitHub Release | `$MP_CORE_DIR`、`$MP_AGH_DIR` |

AGH 运行时可能回写 `agh.yaml`，但仓库模板仍是权威来源。完整配置更新会在 AGH 停止后覆盖正式配置，因此需要保留的 Web UI 修改必须回写仓库模板。

## 3. 配置权威与变量优先级

### 3.1 环境变量

`sh/env.conf` 加载后的优先级为：

```text
调用方显式 MP_* 环境变量
    > $MP_INST_DIR/sh/env.local.conf
    > sh/env.conf 默认值
```

当前持久化参数：

- `MP_INST_DIR`：安装根目录。
- `MP_REPO_RAW_URL`：仓库 Raw 根 URL。
- `MP_PROXY`：唯一外部代理；安装时用于自举，日常作为后备。
- `MP_SUBSCRIBE_URL`：Core provider 订阅模板参数。
- `MP_AGH_USER_NAME`、`MP_AGH_PASSWORD`：AGH 管理员信息。
- `MP_LOCAL_DNS`：AGH 默认直连上游 DNS。

`MP_CORE_DIR` 与 `MP_AGH_DIR` 只能由 `MP_INST_DIR` 派生，不能独立持久化，否则会与服务文件和运行目录失配。

### 3.2 Core 配置是运行参数的唯一基础

外围脚本不得另设全局变量或隐藏默认值来复制以下 Core 字段：

| Core 字段 | 派生用途 |
|---|---|
| `mixed-port`，其次 `port`/`socks-port` | 本机下载代理、AGH `http_proxy`、保活 |
| `external-controller`、`secret` | API 就绪检测、provider API 刷新 |
| `dns.listen` | AGH 代理域名的上游地址 |
| `dns.fake-ip-range` | fake-ip 网络路由 |
| `tun.device` | fake-ip 路由目标接口 |
| `external-ui` | Web UI 安装目录 |
| `proxy-providers`、`rule-providers` | provider 下载 URL、路径及 API 名称 |

相关读取统一通过 `common.sh` 中的受限 YAML 解析函数完成。该解析器只支持项目目前使用的简单顶层标量和顶层 section 的直接子标量，不是完整 YAML 解析器。修改 YAML 排版或嵌套层级时必须同步检查解析逻辑。

`dns.enable`、`dns.enhanced-mode`、TUN 和 fake-ip 在本方案中是必需能力，不通过脚本默认值掩盖错误配置。新 Core 配置写入前必须能派生代理、API、DNS、fake-ip、TUN 和 UI 路径。

## 4. 公共能力边界

所有业务脚本先加载 `common.sh`；`common.sh` 再加载 `env.conf`。公共逻辑主要分为以下几组：

### 4.1 Core 配置解析

- `mp_core_value`：读取受限范围内的 YAML 标量。
- `mp_core_proxy_url`：从 Core 端口生成 curl 或 AGH 可用的代理 URL。
- `mp_core_api_url`：把控制器监听地址转成本机 API URL。
- `mp_core_dns_endpoint`：生成本机可访问的 Core DNS endpoint。
- `mp_core_fake_ip_cidr`：规范化 fake-ip IPv4 CIDR。
- `mp_core_external_ui_path`：解析并限制 UI 目录必须位于 Core home 内。

### 4.2 下载

仓库脚本中的常规文件下载应统一调用 `download_file`，不要在业务脚本中复制代理选择逻辑。

每轮下载顺序固定为：

```text
从当前正式 core/config.yaml 派生的本机 Core 代理
    ↓ 失败或不可用
MP_PROXY 外部代理
    ↓ 失败、不存在或与本机代理相同
强制直连
```

`download_file` 使用目标目录内的临时文件，检查 curl 状态与最小文件大小，成功后以 `mv` 原子替换。交互终端下整轮失败会询问重试，cron 等非交互环境直接失败。

唯一例外是 `inst.sh` 的 bootstrap：此时 `common.sh` 尚不存在，只能用安装器内部的 `bootstrap_download`，顺序是 `MP_PROXY → 直连`。bootstrap 完成后所有下载都回到公共函数。

### 4.3 模板与资源预下载

- `mp_render_template`：用环境中同名 `MP_*` 替换 `{MP_*}`。
- `mp_fetch_core_providers`：预下载 Core 配置中 HTTP providers。
- `mp_prepare_agh_config`：下载并渲染 AGH 模板、同步 Core 代理、预下载 filters。
- `mp_fetch_agh_filters`：将过滤器下载到 AGH 约定目录。

所有目标路径解析都应限制在对应工作目录内，避免配置中的路径导致任意文件覆盖或删除。

### 4.4 平台与服务

- `mp_detect_os`：即时识别 `openwrt` 或 `systemd`，不持久化 OS 类型。
- `mp_service_op`：统一启停和重启服务。
- `mp_sync_etc_files`：处理服务文件中的安装路径并按策略同步到 `/etc`。
- `mp_wait_core_ready`：按当前 Core 配置等待 API 可用。

systemd 的启用逻辑直接创建 `multi-user.target.wants` 链接，不调用 `systemctl enable`，避免同名旧 SysV 脚本触发兼容层错误。

## 5. 安装流程

`inst.sh` 的主要顺序如下：

```text
检查 root、识别平台、确定安装目录
    ↓
立即启用并持久化 net.ipv4.ip_forward
    ↓
加载旧 env.local.conf 和显式环境变量
    ↓
交互收集参数并写 env.local.conf
    ↓
bootstrap 下载 env.conf/common.sh
    ↓
下载仓库 sh/ tarball，处理服务文件路径
    ↓
渲染 Core 配置并预下载全部 HTTP providers
    ↓
下载 Mihomo、AGH、metacubexd UI
    ↓
渲染 AGH 配置并预下载全部 filters
    ↓
生成 AGH dns.conf
    ↓
安装并启动 Core → 等待 Core API → 启动 AGH
    ↓
按用户选择写入 03:00 脚本更新和 03:05 配置更新 cron
```

安装阶段 Core 尚未启动，因此公共下载函数对本机 Core 代理的首次尝试通常失败，然后使用 `MP_PROXY`，最后直连。所有 Core 启动必需文件、AGH filters 和二进制必须在启动服务前准备完成；任何必需步骤失败都停止安装。

服务依赖方向始终为：

```text
网络 → Core → AGH
```

AGH 依赖 Core，因为部分域名上游指向 Core DNS，且 AGH 自身的 `http_proxy` 从 Core 配置生成。

## 6. 更新体系

更新严格分成三类，避免一个入口隐式修改其它类别：

### 6.1 脚本更新

入口：`update-scripts.sh`

1. 通过 `mp_fetch_repo_sh` 下载仓库 tarball。
2. 只覆盖 `$MP_INST_DIR/sh/`，不覆盖 `core/`、`agh/`、`domain/`。
3. `exec` 新版自身，避免旧进程继续执行已被替换的脚本。
4. 重新替换服务文件路径；仅当 `/etc` 中已有对应文件时同步。

`env.local.conf` 不在仓库 tarball 中，不会被覆盖。

### 6.2 配置更新

入口分为：

- `update-all-configs.sh`：只完成下载、渲染和暂存，不重启服务。
- `update-all-configs-restart-services.sh`：调用前者，并按依赖顺序切换服务。

完整更新事务：

```text
保留正在运行的正式 core/config.yaml
    ↓
生成 core/config.yaml.pending，并预下载其 providers
    ↓
用 pending Core 配置生成 agh.yaml.pending，并预下载 filters
    ↓
用 pending Core DNS 地址生成新的 dns.conf
    ↓
所有步骤成功后，将 Core pending 切换为正式 config.yaml
    ↓
停止 AGH
    ↓
将 agh.yaml.pending 切换为正式 agh.yaml
    ↓
重启 Core并等待 API 就绪
    ↓
启动 AGH
```

关键设计是：下载期间正式 Core 配置不变，所以 `download_file` 始终优先使用当前正在运行的旧 Core 代理。任何下载失败都会删除 pending 配置并跳过服务重启。

注意当前事务边界并非完整回滚事务：`dns.conf` 和 provider/filter 数据文件可能已在正式目录中更新；Core 正式配置也会在服务切换脚本停止 AGH 前完成替换。修改此流程时必须明确“下载完成”“配置落盘”“服务切换”三个阶段，不能提前重启 Core，否则后续下载可能失去本机代理。

单项入口：

- `update-core-config.sh`：渲染 Core 配置、验证派生字段并预下载 providers。
- `update-agh-config.sh`：下载域名清单并重新生成 `dns.conf`。
- `update-proxy-rule.sh`：通过当前 Core API 增量刷新 providers。

单独更新 Core 配置不会同步 AGH 的 Core DNS 地址或 `http_proxy`。涉及 Core 端口、DNS、TUN、fake-ip 或 UI 路径时，应使用完整配置更新入口。

### 6.3 二进制更新

入口：`update-bin.sh`

- 根据 `uname -m` 选择 Mihomo 与 AGH 发布架构。
- 从 GitHub latest release 下载 Mihomo、AGH 和 metacubexd。
- UI 目录从当前 Core 配置的 `external-ui` 派生。
- 脚本只替换文件，不自动重启服务。

二进制更新和配置更新相互独立；需要使用新二进制时由调用方安排服务重启。

## 7. AGH 域名分流配置

`update-agh-config.sh` 生成 `$MP_AGH_DIR/dns.conf`：

1. 写入 `MP_LOCAL_DNS`；为空时读取 `/etc/resolv.conf`。
2. 原样追加仓库 `agh/myupstream.txt`。
3. 将 `domain/myproxylist.txt` 和 `domain/gpt.txt` 从 Clash payload 转成 AGH 上游规则。
4. 下载并转换外部 `tld-not-cn.txt` 和 `gfw.txt`。
5. 所有来源成功后才替换正式 `dns.conf`。

转换后的代理域名规则指向从目标 Core 配置读取的 `dns.listen`。因此完整配置更新时必须把 `core/config.yaml.pending` 传入该脚本，确保生成内容和即将启用的 Core 配置一致。

## 8. fake-ip 与路由

`setup-fake-ip-route.sh` 从 Core 配置读取：

- `dns.fake-ip-range`：规范化为网络 CIDR。
- `tun.device`：TUN 接口名。

在 TUN 已存在时，它会删除 Mihomo 可能产生的错误 `<base>/30` 路由，再把完整 fake-ip CIDR 路由到 TUN。

触发方式：

- systemd：Core 启动后由 `ExecStartPost` 延迟调用。
- OpenWrt：网络 hotplug 的 add 事件调用。

透明转发还依赖：

- `net.ipv4.ip_forward=1`。
- 防火墙允许客户端接口进入 AGH/Core 监听端口。
- 防火墙允许客户端接口与 TUN 之间转发。
- 若 nftables 的 `input` 默认策略为 drop，必须允许 Core TUN 内部回送给本机的流量，例如 `iifname "utun" accept`；这类流量可能使用动态端口，不能只按公开服务端口放行。

## 9. 平台服务模型

### 9.1 systemd

- `proxy_core.service` 运行 Mihomo，具备 TUN 所需 capability，并只开放 Core 工作目录写权限。
- `agh.service` 通过 `Requires`/`After` 依赖 `proxy_core.service`。
- 两个 unit 都关闭 systemd 启动频率限制，由 `Restart=on-failure` 负责崩溃恢复。
- 服务文件用 `/etc/proxy` 作为仓库占位路径，安装/更新时替换为实际 `MP_INST_DIR`。

### 9.2 OpenWrt

- `init.d/proxy_core` 和 `init.d/agh` 使用 procd 管理进程及 respawn。
- Core 的 `START=98`，AGH 的 `START=99`；停止顺序相反。
- `hotplug.d/net/99-meta-route` 负责网络事件后的 fake-ip 路由修正。

所有平台差异应收敛在公共服务函数和 `sh/etc/` 模板中，业务更新脚本不应直接分叉 OpenWrt/systemd 命令。

## 10. 修改时必须保持的约束

1. 修改前先确定变更属于脚本、配置还是二进制更新，不得隐式跨越边界。
2. 常规远程文件下载统一走 `download_file`；只有安装 bootstrap 可保留独立实现。
3. 日常下载优先使用当前正式 Core 配置派生的本机代理，然后 `MP_PROXY`，最后直连。
4. 完整更新的全部下载完成前不得重启或停止 Core。
5. AGH 必须在 Core API 就绪后启动；切换 Core 配置时先停 AGH。
6. Core 端口、API、DNS、fake-ip、TUN、UI 等参数只能从目标 Core 配置读取。
7. 新配置必须先写临时或 pending 文件，验证并完成依赖下载后再原子替换。
8. AGH 模板完整更新会覆盖运行期修改，不能假定 Web UI 状态是权威来源。
9. provider、filter、UI 等配置派生路径必须限制在对应工作目录内。
10. 不持久化可即时探测的信息，例如 OS 类型或 CPU 架构。
11. 服务文件路径仍以 `/etc/proxy` 为模板占位时，必须继续经过 `mp_sync_etc_files` 替换。
12. 保持 POSIX `sh` 兼容；公共函数中的变量需使用函数专属前缀，避免无 `local` 环境下污染调用方。

## 11. 常见变更入口

| 需求 | 优先检查的文件 |
|---|---|
| 修改安装交互或安装顺序 | `sh/inst.sh`、`README.md` |
| 修改下载代理或失败处理 | `sh/common.sh` 的 `download_file`、bootstrap 逻辑 |
| 增删本机变量 | `sh/env.conf`、`sh/inst.sh`、模板、`README.md`、本文 |
| 修改 Core 字段或层级 | `core/config.yaml`、所有 `mp_core_*`、配置验证、本文映射表 |
| 修改 AGH 主配置 | `agh/agh.yaml`、`mp_prepare_agh_config`、filter 预下载逻辑 |
| 修改域名分流 | `domain/*.txt`、`agh/myupstream.txt`、`update-agh-config.sh` |
| 修改更新切换顺序 | `update-all-configs.sh`、`update-all-configs-restart-services.sh` |
| 修改服务权限或依赖 | `sh/etc/`、`mp_service_op`、`mp_sync_etc_files` |
| 修改 fake-ip/TUN | `core/config.yaml`、`setup-fake-ip-route.sh`、服务触发器 |
| 支持新 CPU 架构 | `sh/update-bin.sh`，并核对两个上游的实际发布文件名 |

## 12. 修改后的最低检查

仓库目前没有独立测试套件。提交前至少应执行：

```sh
for f in sh/*.sh sh/etc/init.d/* sh/etc/hotplug.d/net/*; do
    sh -n "$f" || exit 1
done
git diff --check
```

涉及配置解析、模板渲染、代理回退或 pending 切换时，还应在临时目录构造最小配置进行针对性验证；涉及服务文件时分别检查 OpenWrt 与 systemd 路径，不能只验证当前宿主平台。
