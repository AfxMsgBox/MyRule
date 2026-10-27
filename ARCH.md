# MyRule 架构说明

本文面向后续维护者和代码代理，集中记录技术架构、实现细节、资源处理、高级维护操作和修改约束。用户安装与运维命令以 `README.md` 为准；修改代码前应先阅读本文及涉及的具体脚本。

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
TODO.md                       待办、暂缓事项及验证限制
tests/test_*.py               无联网、无真实服务操作的回归测试

core/config.yaml              Mihomo 配置模板
agh/agh.yaml                  AGH 配置模板
agh/myupstream.txt            AGH 固定格式的自定义上游片段
domain/*.txt                  Clash payload 格式的域名清单

sh/inst.sh                    精简自举入口（独立下载 / 本地仓库定位）
sh/install-lib.sh             参数、交互、依赖、prepare、apply 与流程编排
sh/install-remote.sh          SSH 探测、上传、远端执行与清理
sh/portable.sh                便携路径解析、SHA-256、安装资源缓存
sh/uninstall.sh               独立卸载入口，默认保留安装数据
sh/env.conf                   全局默认值、环境加载及派生路径
sh/common.sh                  公共解析、下载、渲染、服务控制函数
sh/update-*.sh                各类更新入口
sh/setup-fake-ip-route.sh     fake-ip 路由修正
sh/keeplive.sh                Core 本机代理保活
sh/run-scheduled-update.sh    按连续日间隔执行定时更新
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
- `MP_REPO_BRANCH`：固定仓库 AfxMsgBox/MyRule 的分支名，省略或空值为 main。
- `MP_PROXY`：唯一外部后备代理；安装、自举和日常更新均排在 Core 之后。
- `MP_SUBSCRIBE_URL`：Core provider 订阅模板参数。
- `MP_AGH_USER_NAME`、`MP_AGH_PASSWORD`：AGH 管理员信息。
- `MP_LOCAL_DNS`：AGH 默认直连上游 DNS。

`MP_LOCAL_DNS` 未设置时使用 `223.5.5.5 119.29.29.29`，明确为空时读取 `/etc/resolv.conf`。交互安装可保留原空值，向导输入 `-` 表示清空；静默安装省略 `--dns` 使用默认值，显式 `--dns ''` 才表示空值。

安装入口的优先级与日常脚本不同：无参数交互，有参数默认静默，`--interactive` 可显式进入向导。公开参数由命名参数及默认值确定，不从调用环境或旧配置补齐；向导使用本次参数作为默认值。静默模式必填订阅，并明确选择 bcrypt 哈希或 `--no-auth`；用户名默认 admin。解析后导出本次值，防止子脚本重载旧配置时覆盖。分支默认 main，外部代理默认空；独立自举输入的本次下载代理传给向导。写入本机配置时保留其它自定义行。

`MP_REPO_RAW_URL` 仅为内部派生变量，不再接受配置输入。`env.conf` 在本机配置和调用环境加载后强制重算地址，旧 URL 不迁移；安装器保存时删除旧 URL 行。`MP_REPO_BRANCH_PATH` 使用 jq 对分支名按 `/` 分段编码，再拼接固定 Raw 与 codeload 地址。脚本、模板和仓库规则使用同一分支。jq 是安装和运行更新脚本的依赖；安装器会自动补装，日常更新缺少时仍提示并退出，不用文本替换解析分支 JSON。

`MP_CORE_DIR` 与 `MP_AGH_DIR` 只能由 `MP_INST_DIR` 派生，不能独立持久化，否则会与服务文件和运行目录失配。

`sh/.install-state/forward/` 保存本次安装周期的转发恢复凭据，`sh/.schedule/` 保存调度状态，`core/.fake-ip-route` 保存路由归属记录；均不入库。仓库脚本同步明确排除来源中的 `env.local.conf`、`.install-state/`、`.schedule/`，防止复制另一台设备的状态。

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

### 3.3 本机配置文件写入

`$MP_INST_DIR/sh/env.local.conf` 不入库，由安装器写入。

- 纯 shell 语法，被 `env.conf` `source` 读取。推荐每行 `KEY='value'`，使 `$`、反斜杠等保持原样。bcrypt 哈希必须使用单引号，双引号内的 `$` 仍会被 shell 展开。
- 值内含单引号时，用 `KEY='前半'\''后半'` 表示；安装向导会自动进行该转义。
- 可覆盖第 3.1 节列出的本机参数；`core/` 与 `agh/` 路径固定从 `MP_INST_DIR` 派生，不单独配置。
- 日常更新的优先级（高 → 低）：**系统环境变量 > env.local.conf > env.conf 默认值**（安装器的静默参数规则见第 3.1 节）
  - 临时调试用 `MP_FOO=xxx sh script.sh` 即可压过 env.local.conf。
- 重复运行 inst.sh 时第 3.1 节中各项被 upsert（已存在则替换，不存在则追加），用户加的其它行不动。

AGH 用户名默认 admin。选择设置密码时要求 bcrypt 哈希（`$2a$`、`$2b$`、`$2y$` 前缀）；安装器校验前缀，不校验完整哈希长度，不生成哈希或新增密码工具。向导明确询问是否设置；静默模式要求 `--agh-password` 与 `--no-auth` 二选一。临时 `INST_NO_AUTH` 标志随安装包参数 JSON 传递并校验，但不持久化；持久化的空 `MP_AGH_PASSWORD` 表示免登录。

`mp_prepare_agh_config` 使用 `mp_render_template` 的 AGH 模式重建顶层 users 块：免登录生成 `users: []`；启用认证时用 jq 生成包含 name/password 的 JSON 数组（合法 YAML），正确转义用户名。必须恰好有一个 users 块，否则保留目标文件并失败。安装与后续配置更新共用此逻辑，空密码不会生成带空哈希的账号。

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

`download_file` 使用目标目录内的临时文件，检查 curl 状态与最小文件大小，成功后以 `mv` 原子替换。不做进程、API 或网站预探测，由真实下载决定回退；Core 只读当前正式配置，端口按 mixed-port → port → socks-port 选择首个有效值。相同的 Core/外部代理不重复尝试。

curl 的首个参数为 `--disable`，避免读取用户配置。代理通道使用显式 `--proxy URL --noproxy ''`，直连使用 `--proxy '' --noproxy '*'`，消除系统代理变量与 NO_PROXY 干扰。每次通道尝试与重试都在执行前通过 `mp_log_command` 将脱敏命令写入文件，终端输出资源名称、状态、进度及诊断；不打印原始凭据或 curl 错误。

`mp_log_command` 使用纯 shell 对各参数逐个加引号，不用 eval，不改变实际执行参数。`mp_log_url` 保留项目已知公开来源的路径；其它资源路径、所有查询串/片段、URL userinfo 与 Authorization 头隐藏为 `<redacted>`，代理保留协议及地址端口。命令仅追加到 `MP_LOG_FILE`，不污染终端、函数返回值或 HTTP 状态捕获。`mp_run_download_command` 为依赖包管理器共用“记录后执行”封装，保留退出码及其原生进度；这些函数随共享传输块嵌入独立入口，并提前定义以支持依赖安装前的日志。

独立入口导出真实 `INST_ENTRY_DIR`，模块和子脚本继承同一 `MP_LOG_FILE`。默认路径为入口脚本同目录 `myrule.inst.log`，`--log-file PATH` 覆盖；日常更新未继承该变量时默认写入安装目录 `sh/myrule.inst.log`。`mp_init_log` 要求父目录存在、目标为普通文件且不是符号链接，以 umask 077 创建、chmod 600，并追加而不截断。`mp_log_event` 记录时间戳；阶段函数、`echo_log` 和传输函数记录系统/工具、物理路径、进度、HTTP/curl 状态、重试及退出码。日志初始化失败停止下载；不使用全局 `set -x` 或原始 stdout/stderr 全量转储，避免输入值和认证信息泄漏。

HTTP 传输统一由 `portable.sh` 的 `mp_http_download` 实现；独立 `inst.sh` 嵌入同一传输及进度函数，单元测试强制两份一致。curl 在后台以 silent 模式下载，前台定期读取目标临时文件大小，以 `mp_download_progress` 显示大小、平均速度和耗时；TTY 每秒原地刷新，非 TTY 在开始、首次收到数据、之后每 5 秒及完成时输出行。每 0.2 秒检查下载进程，避免小文件额外等待整秒；终止时回收 curl 并清理私有元数据目录。

HTTP 状态及响应头只保存在私有临时目录。进度只提取最后一个成功响应的数值 Content-Length，重定向的新状态行清除前一个响应长度；兼容 HTTP/2 状态行及 CRLF。总大小未知时显示字节数，不猜测百分比。不会显示原始响应头、URL 凭据或 curl 错误；不再依赖管道转发 curl 进度，避免 awk 输入缓冲和 `tee` 导致进度消失。本地复制及 SSH 缓存读取仍显示对应来源，不伪装成网络下载。

`update-proxy-rule.sh` 仅通过 PUT API 触发 Core 下载，使用同一命令日志函数屏蔽 Authorization，并输出逐项开始/成功/失败；没有字节总量时不伪造百分比。HTTP 200/204 且 curl 退出码 0 才算成功。Core 就绪探测和 keeplive HEAD 属于健康检查，不是资源下载。

每次请求连接超时 10 秒，连续 30 秒传输速度低于 1 B/s 提前终止；分支 API 和 Mihomo 版本 API 总超时 60 秒，其余资源默认 300 秒。每轮依次尝试全部可用通道；最后直连仍为暂态错误时，间隔 1 秒最多重试两轮，共三轮。暂态包含 DNS/连接/传输/握手错误、超时及 HTTP 408/429/500/502/503/504；最终 403/404、证书校验失败、空响应不自动重试，本地读写错误立即终止。

安装模块的 `bootstrap_download` 用于分支 API 和仓库归档。独立 inst.sh 在模块尚不存在时含最小下载自举，优先读取本机 mixed-port，然后发起端代理及直连。模块加载后 bootstrap 和公共下载函数均按 mixed-port → port → socks-port 查找端口。

安装资源准备及目标应用的子进程设置 `_MP_NONINTERACTIVE=1`，失败退出，可重新运行安装器；交互分支查询允许整批重试。日常手动更新保留原终端重试机制。临时变量不写入本机配置。

### 4.3 本地仓库来源

`--local` 根据 inst.sh 的真实路径定位根目录，不依赖当前工作目录；`--source-dir DIR` 显式指定来源。交互本地模式默认填入推断结果。本地源包含未提交修改，但不包含 `env.local.conf`、`.install-state/`、`.schedule/` 或 core/agh 运行数据。

prepare 将 sh/、domain/、core/config.yaml、agh/agh.yaml、agh/myupstream.txt 复制为快照；检查必需文件与路径边界。本机目标不能在源目录内；SSH 模式的源和目标属于不同机器，不作本地路径重叠判断。源根目录支持空格，仓库内文件名及目标安装路径限制为安全字符。

快照复制 `inst_snapshot` 和资源读取 `mp_copy_repo_file` 都先用 `pwd -P` 解析源根目录，再与 `mp_realpath` 解析的文件路径做边界比较；这也适用于自举归档复用路径。不得将逻辑根目录与物理文件路径直接比较，否则 macOS `/tmp` → `/private/tmp` 等符号链接会被误判为越界。解析、越界和复制失败须指出相对文件名，资源读取日志记录逻辑根目录、物理根目录及解析后的文件路径。

快照排除默认 `myrule.inst.cfg`、`myrule.inst.log`，并按真实路径排除当前使用的自定义配置及日志，避免将调试数据和订阅凭据打包上传。

`_MP_SOURCE_DIR` 仅传递给本次准备和应用子进程。`mp_fetch_repo_sh` 同步快照脚本并保留私有配置及安装状态。`download_file` 遇到当前仓库 Raw URL 时映射为快照文件，失败不回退远端；其它 URL 在 prepare 下载并缓存，在 apply 只读缓存。本地安装仍需在发起端联网获取外部文件。分支参数始终保存为后续 GitHub 更新来源，不从本地 git 状态推测。

### 4.4 模板与资源预下载

- `mp_render_template`：用环境中同名 `MP_*` 替换 `{MP_*}`。
- `mp_fetch_core_providers`：预下载 Core 配置中 HTTP providers。
- `mp_prepare_agh_config`：下载并渲染 AGH 模板、同步 Core 代理、预下载 filters。
- `mp_fetch_agh_filters`：将过滤器下载到 AGH 约定目录。
- `mp_install_binary`：在目标文件系统中完成复制及权限设置后，再替换二进制。
- `mp_install_ui`：先准备完整 UI 目录，再切换；切换失败尽力恢复旧目录，恢复失败保留备份路径。

所有目标路径解析都应限制在对应工作目录内，避免配置中的路径导致任意文件覆盖或删除。

### 4.5 平台与服务

- `mp_detect_os`：即时识别 `openwrt` 或 `systemd`，不持久化 OS 类型。
- `mp_service_op`：统一启停和重启服务。
- `mp_activate_configs`：安装/重装与日常更新共用的服务切换流程；停止 AGH、提交待切换配置、重启 Core、等待 API/TUN/路由就绪、重启 AGH。重装使用 `enable_restart`，确保已运行的服务也重新加载；首次安装使用 `enable_start`，无需停止尚未运行的 AGH。
- `mp_commit_pending_configs`：仅提交配置，供上述流程或首次安装选择不启动服务时使用；运行中的 AGH 必须先停止。
- `mp_sync_etc_files`：处理服务文件中的安装路径并按策略同步到 `/etc`。
- `mp_wait_core_ready`：按当前 Core 配置等待 API 可用，同时要求 TUN 接口具有 UP 标志、规范化后的完整 fake-ip CIDR 直接路由到该接口（无 via 网关）。默认总等待 30 秒，失败输出具体原因并保持 AGH 停止；API 请求强制直连。

systemd 的启用逻辑直接创建 `multi-user.target.wants` 链接，不调用 `systemctl enable`，避免同名旧 SysV 脚本触发兼容层错误。

### 4.6 外部下载资源处理

来源、文件及安装位置见 [README 下载列表](README.md#下载列表)。此处记录资源处理方式。


GFW 和非中国顶级域名列表参与生成 `agh/dns.conf.pending`，配置提交后成为 `agh/dns.conf`。程序及面板压缩包解压安装后删除。当前安装流程每次都会请求上述资源，不因本地已有文件而跳过；必需下载失败立即终止后续资源下载、配置切换和服务启动。Mihomo latest JSON 须包含安全且非空的 tag_name；二进制或 UI 下载、解压、安装失败不继续处理后续组件。providers、filters 和 DNS 域名列表在首个失败处停止；DNS 清理临时文件并保留旧配置。已成功更新的其它组件不整批回滚。

订阅和过滤器清单由 `core/config.yaml` 与 `agh/agh.yaml` 决定；修改模板后，下载项也会变化。当前 `whitelist_filters` 为空，没有额外白名单下载；GPT 规则来自本仓库，不列入 README 下载列表。GitHub Release 下载会跟随 HTTP 重定向，表中列的是脚本使用的入口地址。

README 下载列表统计安装脚本主动下载的文件及版本信息，以及补装缺失依赖时由包管理器下载的索引和软件包。软件包使用系统软件源及包管理器自己的代理设置，不走项目的 Core → 外部代理 → 直连链路。服务启动后的订阅/过滤器刷新、`www.gstatic.com/generate_204` 节点健康检查和 DNS 查询属于运行期网络访问，未计入；健康检查不下载安装文件。

GFW 域名列表使用 Loyalsoldier/clash-rules 已整理的 Clash payload，直接转换为 AGH 上游规则；不再下载或解析官方 AutoProxy 列表，也不生成跳过规则报告。

## 5. 安装流程

入口与模块职责：

| 文件 | 职责 |
|---|---|
| `inst.sh` | 定位本地模块；独立脚本补齐最小工具、下载分支归档并加载模块 |
| `install-lib.sh` | 统一编排、参数与向导、依赖、来源和缓存、目标应用、恢复快照与定时任务 |
| `install-remote.sh` | SSH 探测、连接复用、传输、远端预检及清理 |

安装器归并为以上三个文件；`portable.sh` 是安装与日常更新共用的运行库。`install-lib.sh` 被 source 时仅定义函数，只有显式 `--installer-run` 才执行入口。独立 inst.sh 自动下载仓库并调用库入口，本机在线和 SSH 在线均不要求事先下载其它文件。CLI 静默自举使用 `--branch`，未指定时使用 main。独立交互入口在下载模块前分页获取 GitHub 分支列表（main 置顶），`--branch` 只预设默认编号；API 失败或响应无效时停止，不用不完整列表继续下载。确认分支后下载其归档，以 `_INST_BOOT_SELECTED` 传递原始分支名、`_INST_BOOT_BRANCH` 传递 URL 编码后的分支名；向导沿用选择，prepare 复用同一归档，避免重复选择和下载。独立文件无法推断下载来源分支，所选分支缺少 install-lib.sh 时提示具体分支和缺失文件。本地仓库入口仍在完整向导中查询分支。

支持三条路径：本机在线、SSH 在线、SSH 本地仓库；另保留本机本地仓库安装。发起端适配 Linux/macOS/OpenWrt；安装目标为 OpenWrt/procd 和 Linux/systemd。macOS 仅作为资源下载与 SSH 部署发起端，不安装或运行代理服务，无需实现 launchd、macOS TUN、路由及服务卸载适配。

命令行支持 `--key value` / `--key=value`，无参数交互，有参数默认静默；`--interactive` 可带预设参数进入向导。必填订阅，认证选择 bcrypt 哈希或 `--no-auth`，用户名默认 admin，目录默认 /etc/proxy、分支 main、DNS 默认值保持原样。安装路径要求安全绝对路径。SSH 参数含用户@主机、端口、私钥、auto/password/key。间隔参数 `--scripts-days` / `--configs-days` 为 1–365，省略保留已有任务；`--no-start` 延后配置启用。

```text
入口定位/获取模块 → 检查发起端依赖 → 收集并校验参数
    ↓
本机识别或 SSH 只读探测目标 OS、CPU、UID、sudo 可用性
    → 检查目标 TUN 设备
    ↓
prepare：固定仓库快照 → 按目标 CPU 下载全部外部资源
    → 保存参数 JSON → 生成并核对逐文件 SHA-256 清单
    ↓
本机 apply，或 SSH 上传归档和依赖预检脚本
    ↓
目标补齐软件源依赖 → 校验归档哈希 → 解包 → 校验清单、参数、OS/CPU
    ↓
创建安装目录、记录并设置 IPv4 转发、写 env.local.conf、同步脚本
    ↓
只读快照/缓存，复用既有更新脚本生成 pending 配置、安装程序和 UI
    ↓
清除缓存/来源临时环境 → 按原顺序切换服务 → 设置所选更新任务
```

prepare 在私有临时目录运行既有配置/二进制更新器，以 `_MP_TARGET_ARCH` 指定目标 CPU，不执行下载的目标程序。`_MP_CACHE_WRITE` 按 URL 的 SHA-256 保存响应正文及内容校验值。目标 apply 设置 `_MP_RESOURCE_DIR` 后，外部资源缺失或校验失败立即退出，绝不联网回退；配置在目标重新渲染，因此路径和空 DNS 的 `/etc/resolv.conf` 使用目标值。日常更新不继承这些临时选项。

本机目标在 prepare 前检查 `/dev/net/tun` 为可打开的字符设备；SSH 初探只检查设备类型，避免误拒绝需要 sudo 的用户，目标以 root 预检及 apply 时复查打开权限。设备缺失或不可访问时停止并提示宿主机开放 TUN；不自动创建设备。`--no-start` 同样检查，macOS 等纯发起端不检查 TUN。

完整安装包包含 repo/、resources/、config.json、manifest；仅快照代码、模板及规则进入 repo。清单核对文件集合、内容哈希及类型，拒绝符号链接、额外文件、路径跳转。包含订阅与管理员参数的临时目录使用 0700，参数文件受 umask 077 保护。哈希用于完整性检查，传输身份和保密性由 SSH 负责，不将其描述为发行签名。

`inst_load_config` 严格核对参数字段集合与字符串类型，使用 `explode | index(0) == null` 排除 NUL；部分 OpenWrt jq 的 `contains("\u0000")` 会对普通字符串返回 true，不能用于此校验。校验失败须输出脱敏原因，不能静默退出。

OpenWrt 的 jq 可不带 Oniguruma 正则库；安装与更新不得依赖 jq 的 `test/match/sub`。分支名、分支 API 响应和 Mihomo tag_name 使用字符码或字符集合校验，保留原字符约束，不要求额外安装正则库。

SSH 使用 OpenSSH ControlMaster 复用连接，原生支持默认密钥、agent、指定私钥及交互密码。保留主机密钥检查，不提供明文密码命令行选项。上传通过 SSH 标准输入完成，不依赖远端 SFTP/scp。非 root 目标要求 sudo；远端安装分配 TTY，允许原生 sudo 密码提示。只将经过限制的临时路径和哈希拼入远端命令，敏感安装参数走文件；结束时清理私有临时目录及连接。异常断线/断电可能遗留临时目录，真实恢复行为待验证。

SSH 设置 `LogLevel=ERROR`，抑制正常 TTY 结束的 `Shared connection ... closed` 信息，保留错误和认证交互。远程安装返回 0 后，发起端输出明确成功及会话正常结束；非零返回失败，255 单独提示连接异常、结果无法确认，并保留原退出码。`inst_print_result` 仅在部署和定时任务设置成功后调用，区分服务已启动与 `--no-start` 的文件部署成功，维护命令注明须在安装设备上执行。

目标机日志 `commands.log` 由 SSH 登录用户在私有临时目录内创建，确保 sudo 部署后仍可读取；预检及 apply 继承该路径。远端退出时清理 bundle，保留日志，由发起端取回追加到同一安装日志后统一清理临时目录。取日志失败仅提示警告，不能覆盖原部署退出码。

`--download-proxy` 只属于发起端，SSH 模式默认空；`--proxy` 保存为目标机后备代理。本机安装未显式给 download-proxy 时沿用 proxy。资源准备读取发起端现有 Core（本机目标目录，SSH 发起端 /etc/proxy）；在 staging 中用 `_MP_DOWNLOAD_CORE_CONFIG` 指向它，不能误用目标地址或 staging 配置。后续目标更新仍为自己的 Core → MP_PROXY → 直连。

向导走 /dev/tty 的 fd 3，可见输入、空行保留默认值，DNS 输入 `-` 清空。所有来源均分页获取 GitHub 分支列表，main 置顶；本地来源所选分支用于后续在线更新。密码选择默认不设置，选择设置后输入用户名及 bcrypt 哈希。颜色仅对 TTY 启用，NO_COLOR/TERM=dumb 禁用，日志不显示订阅或代理凭据；SSH 自身管理密码输入。

`--fill-from [PATH]` 强制交互模式，省略 PATH 时使用入口同目录 `myrule.inst.cfg`；不带参数不读取或写入任何默认值文件。配置为 JSON 对象，所有值必须为不含 NUL 的字符串；不 source/eval 配置内容。`prompt_to` 按变量名读取默认值（含空字符串），缺键回退原默认值，每次输入后以同目录临时文件和原子 mv 写回，权限 0600；日志只记字段名。分支保存 `MP_REPO_BRANCH` 名称，动态映射列表序号，不保存序号。独立入口与安装模块共用上述函数；配置路径与日志相同、文件非法或保存失败均停止，SSH/sudo 密码不进入配置。

外部下载清单保留在 [README 下载列表](README.md#下载列表)。每次安装重新准备最新资源，不因目标已有文件跳过。只有下载与包校验成功才开始覆盖目标项目文件；软件依赖补装不在此保证范围内。覆盖应用不承诺整批事务回滚。

安装开始时若已存在 Core 主配置、AGH 主配置或 dns.conf，则按重装处理。选择不启用服务时，重装保留三份 pending 配置及原正式配置；首次安装则直接提交三份配置，不启动服务。安装器会打印相应手动应用命令。此选择不撤销此前的 IPv4 转发、本机参数、脚本、二进制/UI 和 provider/filter 资源更新。

提交配置按文件依次替换，不是整批原子事务。若 AGH 停止失败，正式配置保持不变；停止后的配置提交或 Core 启动失败，则保留 AGH 停止状态并报错，避免使用混合配置自动恢复服务。

服务依赖方向始终为：

```text
网络 → Core → AGH
```

AGH 依赖 Core，因为部分域名上游指向 Core DNS，且 AGH 自身的 `http_proxy` 从 Core 配置生成。

安装器还会开启 `net.ipv4.ip_forward`：systemd 系统持久化到较晚加载的 `/etc/sysctl.d/99-zz-myproxy.conf`，OpenWrt 持久化到 `/etc/sysctl.conf`，并读取 `/proc/sys/net/ipv4/ip_forward` 验证是否已经即时生效。LXC 等受限环境无法修改内核参数时会明确警告，但不会中断安装，需要在宿主机侧放行。

首次改动转发设置前，`inst_record_forward_state` 在 `sh/.install-state/forward/` 原子保存安装目录、平台、配置文件原有/不存在标记、原文件快照、预计安装后的快照及运行值。目录权限为 700；状态不通过 source 执行。保存失败停止安装，重装沿用首次记录；已完成卸载的 `restored` 标记允许下次安装重新采集原值。已有旧配置但缺少记录时不把重装时的值冒充最初原值，提示无法自动恢复旧改动。

### 5.1 系统依赖自举

独立 inst.sh 先补齐 curl/jq/tar/CA，随后加载模块执行完整检查；浏览器下载也适用。发起端只检查下载、解压、校验及 SSH 工具，不安装 ip/sysctl 等目标工具。目标执行完整依赖检查，并在写入项目文件前按需补齐 cron/flock。未识别的软件包管理器提示手动补齐；不安装或切换服务管理器。独立自举尚未加载完整解析器，某些无效参数可能在自举下载后才被拒绝。

| 检查项 | Debian/Ubuntu 软件包 | OpenWrt 软件包 |
|---|---|---|
| `curl`、`jq`、`tar`、`sed`、`grep` | 同名包 | 同名包 |
| 系统 CA bundle | `ca-certificates` | `ca-bundle` |
| `gzip`、`gunzip` | `gzip` | `gzip` |
| `ip` / `sysctl` / `logger` | `iproute2` / `procps` / `bsdutils` | `ip-tiny` / `procps-ng-sysctl` / `logger` |
| `awk` / `find` | `mawk` / `findutils` | `gawk` / `findutils-find` |
| `cat chmod cp mv rm mkdir mktemp dirname basename readlink date sleep head sort tr wc ln uname id` | `coreutils` | 各自的 `coreutils-<命令>` |
| `ssh`（SSH 发起端） | `openssh-client` | `openssh-client` |
| `sha256sum`（无 shasum 时） | `coreutils` | `coreutils-sha256sum` |
| `crontab` / `flock`（用户选择定时任务时） | `cron` / `util-linux` | `busybox` / `flock` |

按 `command -v` 检查命令，已有 BusyBox applet 可直接满足依赖，不因包名不同重复安装。证书检查系统 `/etc/ssl/certs/ca-certificates.crt` 或 `/etc/ssl/cert.pem` 是否可读且非空；不执行联网探测。只对缺失项映射包名、去重后批量安装，再清除 shell 命令缓存并复查全部依赖。包管理器返回成功但工具或证书仍缺失时，也返回失败；例如定制 OpenWrt 的 BusyBox 禁用了 crontab 时，需使用提供该功能的固件或包，不能将安装 busybox 成功视为功能已可用。

OpenWrt 优先选择可用的 apk，否则 opkg；Debian/Ubuntu（含通过 `ID_LIKE` 识别的衍生系统）使用 apt-get。其它 systemd 系统在依赖齐全时仍可继续，缺失时提示手工补齐。软件包操作仅刷新索引并安装缺失项，不执行整体 upgrade、不修改软件源或永久代理配置，也不关闭 TLS/签名校验。操作使用包管理器自身的网络配置；用户提供的 `MP_PROXY` 不参与这一阶段。apt-get 使用非交互模式，所有包管理器均从 `/dev/null` 读取标准输入，避免吞掉管道中的脚本或向导输入。

刷新索引或安装失败时保留原始错误输出，打印退出码及手动安装命令并停止。软件包补装不提供回滚，已安装的包保留。没有选择定时任务时不检查 crontab/flock。macOS 使用系统 shasum；缺少其它工具时调用已有 Homebrew，未安装 Homebrew 时提示手动补齐。非 root Linux 发起端补包使用 sudo。

包管理器命令参照 [OpenWrt opkg/apk 对照](https://openwrt.org/docs/guide-user/additional-software/opkg-to-apk-cheatsheet)，基础命令拆包参照 [OpenWrt coreutils 定义](https://github.com/openwrt/packages/blob/master/utils/coreutils/Makefile)。`unzip` 仅用于用户在运行安装器前解压 GitHub ZIP，不是脚本自身的运行依赖，安装方法放在 README。

## 6. 更新体系

更新严格分成三类，避免一个入口隐式修改其它类别：

### 6.1 脚本更新

入口：`update-scripts.sh`

1. 通过 `mp_fetch_repo_sh` 下载仓库 tarball（本地来源标志只由安装器传给本次子进程）。
2. 只覆盖 `$MP_INST_DIR/sh/`，不覆盖 `core/`、`agh/`、`domain/`。每个文件在目标目录中暂存，复制后设置权限，再以 mv 替换：`*.sh`、`etc/init.d/*`、`etc/hotplug.d/*` 为 0755，其余配置（包括 systemd unit）为 0644。权限设置失败保留该目标文件并中止同步，先前已完成的文件不回滚；安装也使用同一函数。私有 env.local.conf 及状态文件不参与同步，权限不变。
3. `exec` 新版自身，避免旧进程继续执行已被替换的脚本。
4. 重新替换服务文件路径；仅当 `/etc` 中已有对应文件时同步。

`env.local.conf` 不在仓库 tarball 中，不会被覆盖。

### 6.2 配置更新

入口分为：

- `update-all-configs.sh`：下载、渲染并写入 Core 正式配置、dns.conf、providers 和 filters；只有 AGH 主配置暂存，不重启服务。
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
重启 Core并等待 API、TUN 和 fake-ip 路由就绪
    ↓
启动 AGH
```

关键设计是：本轮下载期间正式 Core 配置不变，所以 `download_file` 仍从旧配置派生本机代理。任何下载失败都会删除 Core/AGH pending 配置并跳过服务重启。单独执行下载入口并退出后，Core 正式配置已经更新，运行进程却可能仍使用旧配置；后续下载不保证能连接从新配置派生的代理端口。常规运维应使用带服务切换的完整入口。

注意当前事务边界并非完整回滚事务：`dns.conf` 和 provider/filter 数据文件可能已在正式目录中更新；Core 正式配置也会在服务切换脚本停止 AGH 前完成替换。修改此流程时必须明确“下载完成”“配置落盘”“服务切换”三个阶段，不能提前重启 Core，否则后续下载可能失去本机代理。

单项入口：

- `update-core-config.sh`：渲染 Core 配置、验证派生字段并预下载 providers。
- `update-agh-config.sh`：下载域名清单并重新生成 `dns.conf`。
- `update-proxy-rule.sh`：通过当前 Core API 增量刷新 providers。

单独更新 Core 配置不会同步 AGH 的 Core DNS 地址或 `http_proxy`。涉及 Core 端口、DNS、TUN 或 fake-ip 时，应使用完整配置更新入口。修改 `external-ui` 还需通过 `update-bin.sh` 部署 UI 到新目录；配置更新不会迁移 UI，操作顺序见本文第 6.4 节。

### 6.3 二进制更新

入口：`update-bin.sh`

- 根据 `uname -m` 选择 Mihomo 与 AGH 发布架构。
- 从 GitHub latest release 下载 Mihomo、AGH 和 metacubexd。
- UI 目录默认从当前 Core 配置的 `external-ui` 派生；可选第一参数指定目标 Core 配置，安装器用它传入 pending 文件。该参数不改变下载代理来源。
- 脚本只替换文件，不自动重启服务。
- 二进制先在目标目录准备临时文件并设为可执行，再原子替换；UI 先复制完整目录，再保留旧目录并切换。任一步安装失败都返回非零，不打印该组件的成功消息。

二进制更新和配置更新相互独立；需要使用新二进制时由调用方安排服务重启。

### 6.4 面板目录迁移

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

### 6.5 fake-ip 缓存维护

通过 Core API 清理缓存，按配置携带鉴权信息：

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

### 6.6 定时任务

交互安装只询问两项：“每隔几天更新脚本？”和“每隔几天更新配置？”，默认 3 天，范围 1–365，输入 n 跳过并保留对应旧任务。选中任一任务后补齐 crontab/flock，再写 root crontab：

```cron
0 3 * * * sh '/etc/proxy/sh/run-scheduled-update.sh' scripts 3 # MyProxy:update-scripts
5 3 * * * sh '/etc/proxy/sh/run-scheduled-update.sh' configs 3 # MyProxy:update-configs
```

第三个参数位置的数字是用户填写的间隔（上例均为 3）；cron 每天触发检查，到期才执行。调度器以 `date +%s / 86400` 的 UTC 连续日编号计算日期差，跨月不重置，不承诺精确到小时的 N×24 小时间隔。首次设置时写入当前日作为起点；之后只有目标更新成功才原子更新 `sh/.schedule/scripts.last` 或 `configs.last`，失败则次日重试，关机错过的任务在下次定时检查补做一次。系统时钟回拨时等待日期重新达到间隔。

间隔保存在 cron 参数里，成功日记录随本机状态保留；重复安装保留已有日期记录，调整间隔后在下次检查按新值判断。安装器仅替换匹配本安装目录、命令和 marker 的对应任务，兼容清理旧的直接调用更新脚本的 cron；读取 crontab 异常时停止该项写入，不覆盖未知任务。卸载同时识别新旧形式。

两个任务共享 `sh/.schedule/lock` 的非阻塞 flock，自动更新相互串行；锁忙时跳过本次检查，次日再试。例如脚本更新超过 5 分钟，配置更新可能顺延一天。手动更新、安装和卸载不加入此锁，仍不支持与自动更新并发操作。调度器通过整体函数执行以应对自身文件在脚本更新时被替换；对子进程设置 `_MP_NONINTERACTIVE=1`，不询问下载重试。脚本更新调用 `update-scripts.sh`，配置更新调用 `update-all-configs-restart-services.sh`，仅后者重启 Core/AGH。

OpenWrt 写入至少一项任务后会启用并重启 cron 服务。`.schedule/` 不属于仓库内容，脚本同步不会覆盖；普通卸载保留，purge 随 sh/ 删除。命令行未给出间隔时保留定时设置。按用户要求，本次间隔调整未运行测试，真实日期推进、跨月和并发行为待验证。

## 7. AGH 域名分流配置

`update-agh-config.sh` 生成 `$MP_AGH_DIR/dns.conf`：

1. 写入 `MP_LOCAL_DNS`；为空时读取 `/etc/resolv.conf`。
2. 原样追加仓库 `agh/myupstream.txt`。
3. 将 `domain/myproxylist.txt` 和 `domain/gpt.txt` 从 Clash payload 转成 AGH 上游规则。
4. 下载 Loyalsoldier/clash-rules 的 `tld-not-cn.txt` 和 `gfw.txt`，按 Clash payload 转换。
5. 所有来源成功后才替换正式 `dns.conf`。

转换后的代理域名规则指向从目标 Core 配置读取的 `dns.listen`。因此完整配置更新时必须把 `core/config.yaml.pending` 传入该脚本，确保生成内容和即将启用的 Core 配置一致。

该脚本第二个可选参数指定输出文件。安装器使用 `dns.conf.pending`，日常更新省略该参数，仍替换正式 dns.conf。最终写入失败必须返回非零。Core 的 `rule_gpt.url` 同样通过 `{MP_REPO_RAW_URL}` 渲染，确保 Core 与 AGH 使用同一分支的 GPT 域名清单。

## 8. fake-ip 与路由

### 8.1 客户端接入与主路由

当前模板中，AGH 监听 TCP/UDP 53，代理域名上游为本机 Core DNS `127.0.0.1:253`。Core 的 `dns.fake-ip-range: 198.18.0.1/16` 对应路由网络 `198.18.0.0/16`，TUN 接口为 `utun`；`auto-route` 和 `auto-redir` 均关闭。DNS 返回 fake-ip 与后续客户端数据连接是两个阶段，客户端必须能把这个网段的流量送达 TUN。

- 安装在主路由时：DHCP 向客户端下发本机 AGH 地址，客户端网关仍为主路由，本机路由将 fake-ip 流量送往 TUN。
- 安装在同一 LAN 的独立设备时：DHCP 下发独立设备的 AGH 地址，客户端网关仍为主路由；主路由需配置 `198.18.0.0/16 via <安装设备 LAN IP>`，安装设备再将该网段路由到 TUN。真实 IP 流量仍按主路由原有路由转发。安装设备需有正常的上网路由及返回客户端的路径。

脚本仅维护安装设备上的 fake-ip → TUN 路由，并由安装器开启 IPv4 转发；不会配置主路由 DHCP、远端静态路由、防火墙或解决已有 DNS 服务的端口冲突。AGH 与 dnsmasq 等服务不能争用同一监听地址的 53 端口；调整 DNS 监听不等于关闭 DHCP。客户端使用外部 DNS（包括外部 DoH）可能绕过 AGH 分流。

README 的接入示例限定为上述 IPv4 拓扑；跨网段、容器 NAT 或其它策略路由环境需另外确认可达性和回程。修改 Core fake-ip 网段后，外部主路由的静态路由也需要人工同步，不能假定本机更新脚本会覆盖它。

### 8.2 本机路由维护与防火墙

`setup-fake-ip-route.sh` 从 Core 配置读取：

- `dns.fake-ip-range`：规范化为网络 CIDR。
- `tun.device`：TUN 接口名。

在 TUN 已存在时，它会删除 Mihomo 可能产生的错误 `<base>/30` 路由，再把完整 fake-ip CIDR 路由到 TUN。

成功后将 CIDR、TUN 名称、内核 ifindex 和 boot_id 原子写入 `core/.fake-ip-route`，供卸载识别归属。状态位于 Core 可写目录中。无法读取接口身份时记录日志，卸载依靠 TUN 销毁自动移除路由，不猜测同名接口归属。

旧 `/30` 路由不存在可忽略，但完整网段路由设置失败会记录错误并返回非零。现有服务触发器如何处理退出码保持不变。

触发方式：

- systemd：Core 启动后由 `ExecStartPost` 延迟通过 `/bin/sh` 调用。现有 `|| true` 保持不变，路由失败不让 Core 服务启动失败。
- OpenWrt：网络 hotplug 的 add 事件通过 `/bin/sh` 调用。

上述调用不依赖路由脚本的执行位；脚本之间通过 sh 调用或 source 加载也不要求执行位。直接运行脚本仍需要执行权限，由安装/更新同步统一设置。

透明转发还依赖：

- Linux 的 `/dev/net/tun` 可访问；LXC 需要宿主机配置设备访问与挂载。安装器不会修改宿主机容器配置。
- `net.ipv4.ip_forward=1`。
- 防火墙允许客户端接口进入 AGH/Core 监听端口。
- 防火墙允许客户端接口与 TUN 之间转发。
- 若 nftables 的 `input` 默认策略为 drop，必须允许 Core TUN 内部回送给本机的流量，例如 `iifname "utun" accept`；这类流量可能使用动态端口，不能只按公开服务端口放行。

实测边界：Mihomo 在 TUN 创建失败时仍可能启动控制 API、DNS 和显式代理监听。安装前设备检查及 `mp_wait_core_ready` 的接口/路由验收防止仅凭 API 在线报告成功，但不验证真实代理节点上网、客户端路由和防火墙配置；这些仍需端到端验证。平台开机路由触发器保持原机制。

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

### 9.3 卸载流程

`uninstall.sh` 独立于 common.sh/env.conf，不加载或执行本机配置，不联网。默认目录为 `/etc/proxy`；支持 `--install-dir DIR`（或等号形式）、`--purge`、`--yes`、`--help`。除单独帮助外要求 root。无参数时先询问是否删除安装文件，回车默认保留，再展示范围并确认卸载，最终确认回车取消。带参数时保留原语义：仅 `--purge` 要求删除，`--yes` 跳过终端确认。无终端且未指定 `--yes` 时拒绝执行。不继承 MP_INST_DIR，以命令行目标为准。

执行顺序：

1. 检查目标路径；purge 额外检查安装凭据、三个子目录的符号链接和 `/proc/self/mountinfo` 中的挂载点。
2. 预检 systemd、init.d、hotplug 和自启动链接归属。unit 要求项目 Documentation 及 ExecStart 中的精确安装路径；init.d 要求 MP_INST_DIR、env.conf 加载及 procd 标记；hotplug 要求目标脚本路径，精确兼容旧版 `exec 路径` 和新版 `exec /bin/sh 路径` 两种格式。systemd 另检查实际 FragmentPath、LoadState、DropInPaths，避免停止被其它 unit 或覆盖配置接管的服务。冲突时整体中止，不修改 cron 或服务。
3. 读取 root crontab，生成仅剔除目标安装器任务的新版本。注释、其它安装路径及手工任务保留；读取失败中止，不能将错误当作空 crontab。有转发恢复记录时校验其目录、平台、格式及当前文件是否等于安装前/后快照；配置被另外修改时整体中止。交互确认后重新检查归属、crontab、转发快照及 purge 边界。
4. 提交 cron 清理，按 AGH → Core 顺序停止服务；检查 `/proc/*/exe` 是否仍指向目标二进制（包括已删除但运行中的旧文件），有残留则保留文件和数据并失败。读取路由记录，仅在同一 boot_id、TUN 的 ifindex 仍一致、路由仍为记录的 CIDR 与设备且没有 via 网关时清理残留；接口不存在表示内核已随接口销毁清理，跨启动周期或同名接口重建则保留其路由。无记录时不猜测路由归属。
5. OpenWrt 禁用服务；移除已核对的自启动链接、服务文件和 hotplug。systemd 直接删除启用链接再 daemon-reload，避免 systemctl disable 触发旧 SysV 兼容同步。
6. 有恢复凭据时恢复安装前的转发配置文件，原文件不存在则删除安装器新增文件；运行值仅在仍为安装器设置的 1 且原值为 0 时恢复为 0。成功后写入 `restored` 标记，重复卸载不重放恢复操作。失败保留记录和数据供重试；旧安装没有记录时提示并保留转发设置。
7. 默认保留数据。显式 purge 或无参数交互选择删除时，在重查路径及进程后仅删除目标的 core/、agh/、sh/；随后用 rmdir 删除已空的安装根目录；若仍有其它文件则保留并提示。空目录因权限或挂载原因无法删除时返回失败；不会递归删除根目录中的其它内容。清理顺序将 sh/ 放最后，整个卸载流程位于函数中，支持删除当前执行的脚本。

`env.local.conf` 仅作为安装凭据以文本匹配 MP_INST_DIR，不执行其中内容。服务命令失败、链接/文件删除失败、daemon-reload 失败都返回非零，后续数据清理不执行；流程不承诺回滚已经移除的 cron 或停止的服务。

卸载只撤销有归属依据的安装器改动，不调用 apk/opkg/apt，不移除软件包、不停止系统 cron，不清理用户手工任务、系统日志、主路由静态路由或防火墙。安装前已启用的转发保持启用；旧安装的未记录原值无法追溯。安装后共享 sysctl 文件发生变化时不能用完整快照覆盖，必须先人工核对。不与安装/更新并发执行，平台开机就绪机制保持原样。

安装器本地来源检查包含 uninstall.sh，在线及本地 sh/ 同步会一起部署卸载脚本。测试只在临时脚本副本替换固定 /etc、/proc、/sys 根路径，用模拟服务管理器、crontab、sysctl 和 ip 检查行为；生产脚本不提供系统根目录环境覆盖选项。

## 10. 修改时必须保持的约束

1. 修改前先确定变更属于脚本、配置还是二进制更新，不得隐式跨越边界。
2. 常规远程文件下载统一走 `download_file`，它与安装 bootstrap 均调用 `mp_http_download`；独立入口嵌入同一传输函数并通过测试保证一致。
3. 所有安装和日常下载优先使用当前正式 Core 配置派生的本机代理，然后 `MP_PROXY`，最后直连。
4. 完整更新的全部下载完成前不得重启或停止 Core。
5. 安装及完整更新的服务切换流程须等待 Core API、TUN 与 fake-ip 路由就绪后启动 AGH。重装提交正式配置前先停 AGH；日常更新的 Core 落盘边界见第 6.2 节。平台开机启动仍使用现有依赖/顺序机制，不额外增加 API 检查。
6. Core 端口、API、DNS、fake-ip、TUN、UI 等参数只能从目标 Core 配置读取。
7. 新配置必须先写临时或 pending 文件，验证并完成依赖下载后再原子替换。
8. AGH 模板完整更新会覆盖运行期修改，不能假定 Web UI 状态是权威来源。
9. provider、filter、UI 等配置派生路径必须限制在对应工作目录内。
10. 不将 OS 类型或 CPU 架构持久化为运行配置；卸载恢复凭据可记录当时的平台以校验快照归属。
11. 服务文件路径仍以 `/etc/proxy` 为模板占位时，必须继续经过 `mp_sync_etc_files` 替换。
12. 保持 POSIX `sh` 兼容；公共函数中的变量需使用函数专属前缀，避免无 `local` 环境下污染调用方。

## 11. 常见变更入口

| 需求 | 优先检查的文件 |
|---|---|
| 修改卸载与清理范围 | `sh/uninstall.sh`、`tests/test_uninstall.py`、README、本文 |
| 修改安装交互或安装顺序 | `sh/inst.sh`、`sh/install-lib.sh`、`sh/install-remote.sh`、`README.md` |
| 修改下载代理或失败处理 | `sh/portable.sh` 的 `mp_http_download`、`inst.sh` 嵌入函数、`download_file` 与 bootstrap 调用方 |
| 增删本机变量 | `sh/env.conf`、`sh/inst.sh`、模板、`README.md`、本文 |
| 修改 Core 字段或层级 | `core/config.yaml`、所有 `mp_core_*`、配置验证、本文映射表 |
| 修改 AGH 主配置 | `agh/agh.yaml`、`mp_prepare_agh_config`、filter 预下载逻辑 |
| 修改域名分流 | `domain/*.txt`、`agh/myupstream.txt`、`update-agh-config.sh` |
| 修改更新切换顺序 | `update-all-configs.sh`、`update-all-configs-restart-services.sh` |
| 修改服务权限或依赖 | `sh/etc/`、`mp_service_op`、`mp_sync_etc_files` |
| 修改 fake-ip/TUN | `core/config.yaml`、`setup-fake-ip-route.sh`、服务触发器 |
| 支持新 CPU 架构 | `sh/update-bin.sh`，并核对两个上游的实际发布文件名 |

## 12. 修改后的最低检查

测试使用 Python 3 标准库、POSIX shell 与 jq，在临时安装目录中运行 shell 函数及脚本，以模拟命令替代下载和服务操作。覆盖两平台卸载、确认取消、归属检查、cron 精确清理、purge 边界和失败保留数据，以及本地来源校验、路径边界、缺文件失败、私有配置保留、本地安装结合外部代理的完整流程，以及参数解析及空值、无 TTY 拒绝交互、有 TTY 静默不提示、缺失 jq、分支分页与异常响应、代理通道顺序和环境隔离、终端颜色与日志脱敏，以及重装接受/拒绝启动、首次安装、失败中止、参数优先级及空值、特殊字符持久化、分支一致性、配置落盘边界、二进制/UI 安装失败、路由失败，以及两个平台的服务命令派发。提交前至少应执行：

```sh
python3 -B -m unittest discover -s tests -v
for f in sh/*.sh sh/env.conf sh/etc/init.d/* sh/etc/hotplug.d/net/*; do
    sh -n "$f" || exit 1
done
git diff --check
```

`tests/test_download_health.py` 专门覆盖进度与错误脱敏、自动重试上限、永久错误保留旧文件、必需资源失败即停止、目标 TUN 预检及 API 在线但接口/路由缺失等场景。

新增行为应补充相应的失败场景测试。模拟测试不等于真实 OpenWrt/systemd 部署验证；待验证事项记录在 TODO.md。
