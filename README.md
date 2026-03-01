# sing-run - sing-box 代理管理工具

基于 sing-box 的区域化代理管理工具，支持多区域并发、多源切换、TUN 透明代理、自定义域名规则。

## 核心概念

- **每个实例 = (区域, 源, 节点索引)**
- **一个区域只能运行一个实例**
- **所有操作都基于区域**

## 特性

- 🌍 **多区域管理** - 支持 16 个国家/地区，独立端口和 TUN 接口
- 🔄 **多源支持** - 每个区域可使用不同的订阅源，自由切换
- 🚀 **并发实例** - 同时运行多个区域的代理，互不干扰
- 🌐 **TUN 透明代理** - 一键启用全局代理，切换节点/源时自动保持
- 📋 **域名规则** - 自定义代理/直连域名，内置广告拦截和中国域名直连
- ⚡ **完全独立** - 不依赖其他外部工具

## 安装

### 一键安装

```bash
# 克隆后运行安装脚本
git clone https://github.com/VinVC/sing-run.git
cd sing-run
./install.sh
```

安装脚本会自动：
- 检查依赖（sing-box, yq, jq, curl, python3）并提示缺失项
- 配置 `~/.zshrc` 自动加载
- 创建 `sources.sh` 配置文件模板

### 更新 / 卸载

```bash
./install.sh update      # 更新到最新版本
./install.sh uninstall   # 卸载
```

### 前置条件

```bash
# macOS (Homebrew)
brew install sing-box yq jq
```

### 源配置

首次使用前，编辑源配置文件（安装脚本已自动创建）：

```bash
vim /path/to/sing-run/sources.sh
```

编辑 `sources.sh`，配置代理源：

```zsh
# 格式: 显示名 | 短名 | 订阅URL
SING_RUN_SOURCE_DEFS=(
  "MyProvider | mp | https://example.com/subscribe?token=YOUR_TOKEN"
  "Another    | an | https://other.com/api/subscribe"
)

# 节点名称过滤 (过滤非节点行)
SING_RUN_NODE_FILTER_PATTERN="剩余流量|下次重置|套餐到期|用户群|使用说明"
```

- **显示名**: `sing-run status` 中展示的名称
- **短名**: 命令中使用的标识符，也用于文件命名 (`proxies-<短名>.yaml`)
- **订阅URL**: 用于 `sing-run update-nodes`（可省略）
- 颜色自动分配，无需配置

详细说明见 `sources.sh.example`。

## 快速开始

```bash
# 1. 更新节点列表
sing-run update-nodes

# 2. 交互式选择区域启动
sing-run

# 3. 或直接启动指定区域
sing-run jp
```

## 命令参考

### 启动实例

```bash
sing-run                              # 交互式选择区域
sing-run jp                           # 启动日本（使用保存的源和节点）
sing-run jp --source mp               # 指定源启动
sing-run jp --node 2                  # 指定节点启动
sing-run jp --source mp --node 2      # 同时指定源和节点
sing-run jp --tun                     # 启用 TUN 透明代理
```

### 停止 / 重启

```bash
sing-run stop jp                      # 停止日本实例
sing-run stop                         # 停止所有实例
sing-run -x                           # 停止所有实例（兼容 sing-tun）
sing-run restart jp                   # 重启日本（保持 TUN/代理模式）
sing-run restart                      # 重启所有运行中的实例
sing-run untun                        # 关闭 TUN 透明代理（自动重启为普通模式）
```

### 节点操作

```bash
sing-run jp nodes                     # 列出日本的所有节点（所有源）
sing-run jp --node next               # 切换下一个节点
sing-run jp --node prev               # 切换上一个节点
sing-run jp --node 5                  # 切换到指定节点
```

> 切换节点/源时会自动保持 TUN 模式，无需重新指定 `--tun`。

### 源操作

```bash
sing-run sources                      # 查看所有源及节点列表
sing-run jp --source mp               # 为日本切换源
sing-run update-nodes                 # 更新所有源的节点列表
sing-run update-nodes mp              # 更新指定源
sing-run update-nodes mp --url <URL>  # 从指定 URL 更新
sing-run update-nodes mp --file <文件> # 从本地文件更新
```

支持的输入格式：
- **Clash YAML** - 包含 `proxies:` 的 YAML 配置
- **vmess:// 订阅** - base64 编码的 vmess 链接列表

### 域名规则

```bash
sing-run --rules                      # 显示所有自定义规则
sing-run --add-proxy example.com      # 添加到代理列表
sing-run --add-direct corp.com        # 添加到直连列表（本地 DNS + 直连）
sing-run --del-rule example.com       # 删除规则
sing-run update-rules                 # 更新内置路由规则集
```

> 修改规则后会提示是否重启运行中的实例以生效。

### 查看信息

```bash
sing-run status                       # 查看所有运行的实例
sing-run regions                      # 列出所有可用区域
sing-run sources                      # 列出所有可用源及节点
sing-run --help                       # 完整帮助信息
```

## 代理使用方式

### 方式一：TUN 透明代理

启动后系统流量自动通过代理，**无需额外配置**。

```bash
sing-run jp --tun
```

- 需要 root 权限（会提示输入密码）
- 同时只能有一个实例启用 TUN（自动互斥）
- 切换节点/源会自动保持 TUN 模式
- `sing-run status` 中 🌐 标记表示 TUN 已启用

**适用场景**：单实例全局代理、主实例作为默认出口

### 方式二：手动配置代理端口（默认）

启动后通过 SOCKS/HTTP 端口使用代理：

```bash
sing-run jp

# 测试代理
curl -x socks5h://127.0.0.1:7810 https://www.google.com
curl -x http://127.0.0.1:7811 https://www.google.com
```

**浏览器扩展推荐**：
- Chrome/Edge: [SwitchyOmega](https://chrome.google.com/webstore/detail/padekgcemlokbadohgkifijomclgjgif)
- Firefox: [FoxyProxy](https://addons.mozilla.org/zh-CN/firefox/addon/foxyproxy-standard/)

**适用场景**：多实例并发、只需特定应用走代理

## 输出示例

### `sing-run status`

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                      sing-run 实例状态
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  ● 台湾 (tw)  ·  PID 37246
    SOCKS :7830 · HTTP :7831
    ProviderA (pa) · 台湾2 [1/3] · vmess · server:port

  ● 美国 (usa) 🌐  ·  PID 40130
    utun6 · 172.19.0.1/30 · SOCKS :7800 · HTTP :7801
    ProviderB (pb) · 美国01 [0/2] · ss · server:port

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  2 个实例运行中
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### `sing-run sources`

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                        可用代理源
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  [pa] ProviderA · 30 个节点

    区域          数量  节点
    ────────────  ────  ─────────────────────────────────────────
    台湾   tw        3  台湾1 · 台湾2 · 台湾3
    香港   hk        5  香港1 · 香港2 · 香港3 · 香港4 · 香港5
    日本   jp        3  日本1 · 日本2 · 日本3
    美国   usa       6  美国1 · 美国2 · 美国3 · 美国4 · 美国5 (+1)
    ...

  [pb] ProviderB · 40 个节点

    区域          数量  节点
    ────────────  ────  ─────────────────────────────────────────
    台湾   tw        1  台湾01
    香港   hk        8  香港01 · 香港02 · 香港03 · 香港04 · 香港05 (+3)
    日本   jp       12  日本01 · 日本02 · 日本03 · 日本04 · 日本05 (+7)
    美国   usa       2  美国01 · 美国02
    ...

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  运行中的实例
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  tw     台湾       ProviderA (pa) · 节点 1
  usa    美国       ProviderB (pb) · 节点 0

  切换源: sing-run <区域> --source <源名称>
  查看节点详情: sing-run <区域> nodes
```

### `sing-run jp nodes`

列出指定区域在**所有源**下的节点：

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                    日本 (jp) 节点列表
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  ProviderA (pa) · 3 个节点

    #     名称                                    类型
    ──  ────────────────────────────────────────  ────
     0  日本1                                     vmess
     1  日本2                                     vmess
     2  日本3                                     vmess

  ProviderB (pb) · 12 个节点 [当前]

    #     名称                                    类型
    ──  ────────────────────────────────────────  ────
  →  0  日本01                                    ss
     1  日本02                                    ss
     2  日本03                                    ss
    ...
```

- `[当前]` 标记当前使用的源
- `→` 标记当前使用的节点
- 不显示服务器域名

## 域名规则详解

### 内置规则集

sing-run 包含完整的路由规则集（首次启动时自动下载）：

- **广告拦截** - 自动拦截广告域名
- **Google 服务** - Google 相关域名走代理
- **中国域名/IP** - 国内域名和 IP 直连
- **内网域名** - `.lan`, `.local` 等内网域名直连

### 自定义规则

域名规则对所有实例生效，使用 `domain_suffix` 匹配（匹配域名及其所有子域名）。

**代理域名**：流量走代理出口，DNS 通过代理服务器解析。

```bash
sing-run --add-proxy openai.com       # openai.com 及子域名走代理
```

**直连域名**：流量直连，DNS 使用本地路由器解析。适用于公司内网域名或无需代理的域名。

```bash
sing-run --add-direct corp.com        # corp.com 及子域名直连 + 本地 DNS
```

> 当连接公司 WiFi 时，路由器可以解析内网域名。将这些域名加入直连列表，即可在透明代理开启时正常访问。

**自定义规则优先级高于内置规则集。**

## 可用区域

| 代码 | 区域 | SOCKS 端口 | HTTP 端口 | IP 地址 |
|------|------|-----------|----------|---------|
| usa | 美国 | 7800 | 7801 | 172.19.0.1/30 |
| jp | 日本 | 7810 | 7811 | 172.19.4.1/30 |
| hk | 香港 | 7820 | 7821 | 172.19.8.1/30 |
| tw | 台湾 | 7830 | 7831 | 172.19.12.1/30 |
| sg | 新加坡 | 7840 | 7841 | 172.19.16.1/30 |
| kr | 韩国 | 7850 | 7851 | 172.19.20.1/30 |
| in | 印度 | 7860 | 7861 | 172.19.24.1/30 |
| uk | 英国 | 7870 | 7871 | 172.19.28.1/30 |
| de | 德国 | 7880 | 7881 | 172.19.32.1/30 |
| ca | 加拿大 | 7890 | 7891 | 172.19.36.1/30 |
| au | 澳大利亚 | 7900 | 7901 | 172.19.40.1/30 |
| fr | 法国 | 7910 | 7911 | 172.19.44.1/30 |
| ru | 俄罗斯 | 7920 | 7921 | 172.19.48.1/30 |
| tr | 土耳其 | 7930 | 7931 | 172.19.52.1/30 |
| ar | 阿根廷 | 7940 | 7941 | 172.19.56.1/30 |
| ua | 乌克兰 | 7950 | 7951 | 172.19.60.1/30 |

- **TUN 接口**：动态分配（从 `utun6` 开始查找可用接口），保存后复用
- **IP 地址**：每个区域有独立的 `/30` 子网
- **端口规则**：每区域间隔 10，SOCKS 端口为偶数，HTTP = SOCKS + 1

## 使用场景

### 场景一：全局代理

```bash
# 启动日本透明代理，所有流量自动走代理
sing-run jp --tun

# 切换节点（TUN 自动保持）
sing-run jp --node next

# 关闭 TUN，改回手动模式
sing-run untun
```

### 场景二：TUN 主实例 + 手动辅助实例

```bash
# 主实例：日本透明代理（浏览器自动使用）
sing-run jp --tun

# 辅助实例：美国手动端口
sing-run usa

# 指定应用走美国
curl -x socks5h://127.0.0.1:7800 https://api.example.com
```

### 场景三：多区域并发

```bash
# 启动多个区域
sing-run jp
sing-run usa
sing-run tw

# 浏览器用 SwitchyOmega 按需切换：
#   日本 → 127.0.0.1:7810
#   美国 → 127.0.0.1:7800
#   台湾 → 127.0.0.1:7830

# 查看状态
sing-run status

# 只停止美国
sing-run stop usa
```

### 场景四：内网 + 代理并存

```bash
# 开启 TUN 全局代理
sing-run usa --tun

# 内网域名无法访问？添加到直连列表
sing-run --add-direct corp.internal.com

# 重启生效后，内网和外网同时可用
```

## 文件结构

### 数据目录

```
~/.sing-run/
├── instances/                         # 实例运行时数据
│   ├── jp/
│   │   ├── config/config.json         # 生成的 sing-box 配置
│   │   ├── logs/sing-box.log          # 运行日志
│   │   ├── state/
│   │   │   ├── source.txt             # 当前源
│   │   │   ├── node.txt               # 当前节点索引
│   │   │   ├── auto_route.txt         # TUN 状态 (true/false)
│   │   │   └── interface.txt          # TUN 接口名
│   │   └── cache/                     # 规则集缓存
│   ├── usa/ ...
│   └── tw/ ...
├── rules/
│   ├── proxy-domains.txt              # 自定义代理域名
│   └── direct-domains.txt             # 自定义直连域名
├── proxies-pa.yaml                    # 源节点数据（自动生成）
└── proxies-pb.yaml
```

### 项目文件

```
sing-run/
├── install.sh                         # 安装/更新/卸载脚本
├── sing-run.sh                        # 主入口、命令解析
├── sing-run-instance.sh               # 实例生命周期管理
├── sing-run-region.sh                 # 区域定义、节点检索
├── sing-run-source.sh                 # 源查询、订阅更新
├── sing-run-rules.sh                  # 域名规则增删查
├── sing-run-template.sh               # sing-box JSON 配置生成
├── sing-run-system.sh                 # 进程管理、TUN 接口、规则集下载
├── sources.sh.example                 # 源配置模板
├── sources.sh                         # 用户源配置 (gitignore)
└── templates/
    ├── tun-template.json              # TUN 模式配置模板
    └── proxy-template.json            # 普通代理模式配置模板
```

## 架构

### 模块职责

| 模块 | 文件 | 职责 |
|------|------|------|
| 主入口 | `sing-run.sh` | 命令解析、模块加载、帮助信息 |
| 实例管理 | `sing-run-instance.sh` | 启动/停止/重启、TUN 接口分配、进程管理 |
| 区域管理 | `sing-run-region.sh` | 区域定义、节点检索和过滤、交互式选择 |
| 源管理 | `sing-run-source.sh` | 源查询、源文件管理、实例-源绑定、订阅更新与解析 |
| 规则管理 | `sing-run-rules.sh` | 自定义代理/直连域名规则，生成 DNS 和路由规则 |
| 模板引擎 | `sing-run-template.sh` | 基于模板生成 sing-box JSON 配置，注入自定义规则 |
| 系统工具 | `sing-run-system.sh` | 进程管理、TUN 接口发现、规则集下载、DNS 检测 |

### 数据流

```
用户命令 → sing-run.sh 解析
    │
    ├─→ sources.sh (用户配置) → 确定可用源
    ├─→ proxies-*.yaml (节点数据) → 获取节点列表
    ├─→ state/ (实例状态) → 读取当前源/节点/TUN 状态
    ├─→ rules/ (域名规则) → 生成自定义路由和 DNS 规则
    ├─→ template.json → 模板引擎 → config.json
    └─→ sing-box run -c config.json → 启动代理进程
```

### 配置生成流程

```
tun-template.json / proxy-template.json
    │
    ├─ 替换占位符: 端口、节点、接口、IP
    ├─ 注入自定义 DNS 规则 (直连域名 → 本地 DNS)
    ├─ 注入自定义路由规则 (代理/直连域名)
    ├─ 注入内置规则集 (广告、Google、中国域名)
    └─→ config.json
```

### 设计原则

1. **区域为核心** - 所有操作都明确指定区域
2. **无全局状态** - 不使用全局"当前区域"概念
3. **独立实例** - 每个区域实例完全独立（端口、接口、配置、日志）
4. **显式源绑定** - 每个实例绑定到明确的代理源
5. **状态保持** - 切换节点/源时自动保持 TUN 模式

## 故障排查

### 首次启动后无法访问网页

首次启动需下载路由规则集（约 10-30 秒）：

```bash
tail -f ~/.sing-run/instances/jp/logs/sing-box.log
# 等待所有 "download rule-set" 完成
```

也可预先下载：`sing-run update-rules`

### 实例无法启动

```bash
# 检查 sing-box 是否安装
which sing-box

# 检查日志
tail -20 ~/.sing-run/instances/jp/logs/sing-box.log

# 检查端口占用
lsof -i :7810

# 检查进程
ps aux | grep sing-box
```

### TUN 模式需要密码

TUN 模式需要 root 权限创建网络接口，会提示输入 sudo 密码。这是正常行为。

### 内网域名无法访问

开启 TUN 后，DNS 请求由 sing-box 处理，内网域名可能无法解析：

```bash
# 将内网域名添加到直连列表
sing-run --add-direct corp.internal.com

# 直连域名会使用本地路由器 DNS 解析，同时直连访问
```

### 节点连接失败

```bash
# 切换节点
sing-run jp --node next

# 查看所有可用节点（包括所有源）
sing-run jp nodes

# 切换到其他源
sing-run jp --source mp
```

## 许可证

MIT License
