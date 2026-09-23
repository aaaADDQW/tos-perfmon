# TOS PerfMon

TOS 7 性能监测应用 —— 基于 `/proc` 的系统与进程级性能采集、内存泄漏自动检测与可视化。

## 特性

- **纯 `/proc` 数据源** — 不依赖任何第三方库，无侵入，零额外负载
- **进程级精细采集** — RSS、匿名页(堆)、文件页、句柄数、socket 数、线程数
- **系统级指标** — 内存、Slab(内核)、负载、CPU、温度
- **自动泄漏判定** — 线性回归斜率 + 单调性检测 + 增长形态分析 + 阈值告警，
  区分堆泄漏/句柄泄漏/连接泄漏，并把"阶梯式增长"与"持续爬升"分开判定以降低误报
- **主从式进程面板** — 左侧紧凑列表（占用/增长率/名称三种排序，升降序可切），
  右侧就地展开趋势详情，不跳转不弹窗
- **告警直达** — 点击告警条目直接跳到对应进程的时间线，免去手工查找
- **交互式仪表盘** — 内存构成堆叠条、趋势图、泄漏清单、KPI 卡片带迷你走势
- **TOS 原生集成** — 符合 TOS 7 应用规范，应用中心一键安装

## 快速开始

### 构建

```bash
./build.sh              # 仅构建
./build.sh --install    # 构建并安装到本机
```

产物：`tos-perfmon_<版本>_amd64.deb`（如 `tos-perfmon_1.1.0_amd64.deb`）

> ⚠️ 构建脚本强制使用 gzip 压缩（`dpkg-deb -Z gzip`）。
> TOS 应用中心的 Go 解析器只认 gzip/xz，不支持 Ubuntu 22.04 默认的 zstd，
> 否则会报"应用包解析失败"。

### 安装

```bash
# 平台安装（应用中心）会自动创建应用用户
# 手工安装需先建用户：
sudo useradd -r -s /usr/sbin/nologin -d /var/lib/tos-perfmon tos-perfmon
sudo dpkg -i tos-perfmon_1.1.0_amd64.deb
```

### 使用

1. TOS 桌面 → 应用中心 → 已安装 → **性能监测**
2. 点「开始采集」，等待数分钟积累样本
3. 点「分析」查看报告

## 判定原理

### 三个核心判据

| 判据 | 方法 | 阈值（可配） |
|---|---|---|
| **内存斜率** | 对 RSS 时序做最小二乘线性回归 | >10 KB/分 警戒<br>>60 KB/分 临界 |
| **单调性** | 统计相邻采样中递增步骤占比 | >75% 警戒<br>>90% 临界 |
| **句柄/线程增长** | 对 fd/thread 时序求斜率 | >10 个/小时 警戒<br>>60 个/小时 临界 |

### 泄漏类型识别

```
rss_anon 斜率占主导    → heap    (堆泄漏)
fd_socket 斜率显著     → socket  (连接泄漏)
fd_count 斜率显著      → fd      (句柄泄漏)
其他                   → mixed
```

### 判定逻辑

```
斜率超临界                        → 🔴 判定泄漏
斜率超警戒 + 单调性超临界          → 🔴 判定泄漏
斜率超警戒 + 单调性超警戒          → 🟠 疑似泄漏
高内存占用 + CPU活跃度极低 + 正增长 → 加分
```

## 目录结构

```
tos-perfmon/
├── build.sh                        # 构建脚本
├── install.sh / uninstall.sh       # 本机手工装卸辅助脚本
├── pkg/                            # deb 包内容
│   ├── DEBIAN/
│   │   ├── control                 # 包元数据
│   │   ├── preinst / postinst      # 安装脚本
│   │   └── prerm / postrm          # 卸载脚本
│   └── usr/local/tos-perfmon/
│       ├── config.ini              # 应用配置（JSON 格式）
│       ├── ROUTER                  # 平台路由标识（内容为应用 id）
│       ├── tos-perfmon.lang        # 多语言（INI，14 种语言）
│       ├── bin/tos-perfmon         # 后端服务（Python，仅标准库）
│       ├── init.d/tos-perfmon.service
│       ├── nginx/tos-perfmon.conf  # 反向代理（^~ 前缀，避免被平台规则吞掉）
│       ├── images/icons/tos-perfmon.svg
│       └── webui.bz2               # 前端（构建时生成）
└── webui/                          # 前端源码
    ├── index.html                  # 单文件仪表盘（零依赖原生 SVG）
    └── icon.svg
```

## 技术架构

```
┌─────────────────────────────────────────┐
│  TOS 桌面 (iframe)                       │
│    /tos-perfmon/                         │
└──────────────┬──────────────────────────┘
               │ 平台代理 /v2/proxy/tos-perfmon/*
               │ (带 X-Csrf-Token + Cookie)
┌──────────────▼──────────────────────────┐
│  Unix Socket: /var/api/tos-perfmon.sock  │
│                                          │
│  后端服务 (Python, 标准库)                │
│    ├── 采集线程 → /proc/*                │
│    ├── 数据存储 → /var/lib/tos-perfmon/  │
│    └── 分析引擎 → 判定报告                │
└─────────────────────────────────────────┘
```

## API

所有接口通过平台代理访问：`/v2/proxy/tos-perfmon/<api>`

| 接口 | 方法 | 说明 |
|---|---|---|
| `/api/status` | GET | 采集状态、配置、数据量 |
| `/api/start` | POST | 开始采集 |
| `/api/stop` | POST | 停止采集 |
| `/api/report` | GET | 生成分析报告（`?range=1h` 等预设窗口） |
| `/api/timeline` | GET | 单进程或系统时间线（`?pid=N&range=1h`） |
| `/api/alerts` | GET | 告警列表 |
| `/api/config` | GET/POST | 读写配置 |
| `/api/export` | GET | 导出 CSV（`?kind=system\|processes\|process&pid=N`） |
| `/api/samples` | GET | 原始样本（`?limit=N`） |
| `/api/clear` | POST | 清空数据 |

可用时间范围：`10m` `30m` `1h` `3h` `6h` `12h` `1d` `3d` `7d` `all`

## 数据存储

- 原始样本：`/var/lib/tos-perfmon/samples.jsonl`（JSONL，每行一个采样）
- 配置：`/var/lib/tos-perfmon/config.json`
- 日志：`/var/log/tos-perfmon/service.log`

## 已知限制

- **仅支持 x86_64**（`config.ini` 中 `platform: x86_64`，ARM 设备不支持）
- **样本量上限**默认 120000，超出按保留时长自动裁剪
- **判定需要足够样本**：至少 20 个才开始给结论，样本不足时只显示"数据累积中"，不做泄漏判定
- **短期波动**可能误判：建议采集 30 分钟以上再下结论
- **全范围报告内存占用较高**：读取整个保留窗口时峰值约 1.2 GB（受 `json.loads` 限制）。
  日常查看请使用时间范围预设（默认近 1 小时），该路径已做窗口裁剪，开销可忽略。

## 许可

内部测试工具。
