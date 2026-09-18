# TOS PerfMon

TOS 7 性能监测应用 —— 基于 `/proc` 的系统与进程级性能采集、内存泄漏自动检测与可视化。

## 特性

- **纯 `/proc` 数据源** — 不依赖任何第三方库，无侵入，零额外负载
- **进程级精细采集** — RSS、匿名页(堆)、文件页、句柄数、socket 数、线程数、CPU 时间
- **系统级指标** — 内存、Slab(内核)、负载、CPU、温度
- **自动泄漏判定** — 线性回归斜率 + 单调性检测 + 阈值告警，区分堆泄漏/句柄泄漏/连接泄漏
- **交互式仪表盘** — 趋势图、泄漏清单、内存排行、增长排行、全进程明细
- **TOS 原生集成** — 符合 TOS 7 应用规范，应用中心一键安装

## 快速开始

### 构建

```bash
./build.sh              # 仅构建
./build.sh --install    # 构建并安装到本机
```

产物：`tos-perfmon_x86_64.deb`

### 安装

```bash
# 平台安装（应用中心）会自动创建应用用户
# 手工安装需先建用户：
sudo useradd -r -s /usr/sbin/nologin -d /var/lib/tos-perfmon tos-perfmon
sudo dpkg -i tos-perfmon_x86_64.deb
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
├── pkg/                            # deb 包内容
│   ├── DEBIAN/
│   │   ├── control                 # 包元数据
│   │   ├── preinst / postinst      # 安装脚本
│   │   └── prerm / postrm          # 卸载脚本
│   └── usr/local/tos-perfmon/
│       ├── config.ini              # 应用配置（JSON 格式）
│       ├── tos-perfmon.lang        # 多语言
│       ├── bin/tos-perfmon         # 后端服务（Python）
│       ├── init.d/tos-perfmon.service
│       ├── images/icons/tos-perfmon.svg
│       └── webui.bz2               # 前端（构建时生成）
└── webui/                          # 前端源码
    ├── index.html
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
| `/api/report` | GET | 生成分析报告 |
| `/api/config` | GET/POST | 读写配置 |
| `/api/samples` | GET | 原始样本（`?limit=N`） |
| `/api/clear` | POST | 清空数据 |

## 数据存储

- 原始样本：`/var/lib/tos-perfmon/samples.jsonl`（JSONL，每行一个采样）
- 配置：`/var/lib/tos-perfmon/config.json`
- 日志：`/var/log/tos-perfmon/service.log`

## 已知限制

- **仅支持 x86_64**（当前配置）
- **样本量上限**默认 20000，超出自动裁剪一半
- **判定需要足够样本**：至少 3 个，建议 10 个以上（即 100 秒以上）
- **短期波动**可能误判：建议采集 30 分钟以上再下结论

## 许可

内部测试工具。
