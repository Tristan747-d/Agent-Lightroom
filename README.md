# Agent Lightroom

**让 Agent 真正"看懂"照片，并驱动 Adobe Lightroom Classic 完成批量审片与后期。**

全部本机离线运行，零云端依赖，零 API 费用，原片不出本机。

---

## 这是什么

一个把「视觉理解」与「可执行后期」连成闭环的开源实践：

```
原片 ──► [测量层] macOS Vision 精确测量（溢出/锐度/白平衡比值/地平线/人脸）
          [语义层] 本地 VLM 看懂内容（主体/表情/构图/肤色/噪点/雾霾）
          [决策层] 确定性规则出参数（每条带 why，可审计、可复现）
          [执行层] 自研桥接插件写回 Lightroom
          [闭环层] 回读 catalog 自证 + VLM 复查，不合格就微调
```

**核心主张：数值与语义分离。**

- **数值必须来自规则**——小模型给数值会瞎编，且无法审计；
- **语义只能来自模型**——算法无法判断"这是人脸""主体在暗部""这是雾霾"；
- 两者**分歧时以测量为准**（实测 VLM 会把 9.6° 的倾斜说成"横平竖直"）。

---

## 四道工序（每张照片）

```
① VLM 看前期状态  →  ② 套用配方  →  ③ VLM 复查  →  ④ 微调
```

**① 和 ③ 是两次独立的 VLM 读取**，字段集不同：

| | 工序① 看前期 | 工序③ 复查 |
|---|---|---|
| 主字段 | **24** | **21** |
| 定位 | 面向"怎么改"（带位置/依据/人数等子证据）| 面向"改得对不对"（带主体突出度/是否过修/仍存在的问题）|

两次读取都**输出全部字段**，并以 `[完整度]` 自检行核对——`返回 < 要求` 即视为字段丢失，必须重跑。

---

## 快速开始

### 1. 环境要求

- macOS（Apple Silicon 推荐；MLX 需 Apple 芯片）
- Adobe Lightroom Classic（实测 15.5）
- Python 3.10+，Node.js
- 本地 VLM 权重（默认 Qwen3-VL-4B，走 [MLX](https://github.com/ml-explore/mlx)）

```bash
pip install mlx mlx-vlm
```

### 2. 启动桥接服务

```bash
node bridge/server.js
```

### 3. 在 Lightroom 中启用插件

增效工具管理器 → 添加 `Agent Lightroom Bridge.lrplugin` → 启用，
然后：**文件 → 增效工具额外信息 → Agent Lightroom - Start Bridge**

> 该菜单项会启动插件的轮询循环。LR 不会在启动时自动执行插件脚本，
> 因此每次重启 LR 后都需要点一次（或用 `tools/start-lr-bridge.sh` 自动完成）。

### 4. 启动本地 VLM 服务

```bash
tools/al-vlm-server --model ~/models/Qwen3-VL-4B --port 8321
```

### 5. 逐张处理

```bash
tools/al-test3 --limit 5      # 先跑 5 张看看
tools/al-test3                # 全量（支持断点续跑）
```

---

## 工具一览

| 工具 | 作用 |
|---|---|
| `al-see` | 从 LR 预览缓存渲染照片（含当前 develop 效果），供 Agent 读图 |
| `al-vision` | macOS Vision + CoreImage 精确测量（**测原片**）|
| `al-baseline-vision` | 同上，但明确以原片为基准（避免反馈回路）|
| `al-tune` | 决策层：阈值规则出 Lightroom 参数 + why |
| `al-analyze` | 单一入口：测量 + 规则（可叠加 `--vlm`）|
| `al-vlm-server` | 本地 VLM HTTP 服务（OpenAI 兼容）|
| `al-vlm-check2` | 结构化 VLM 读图（工序①/③，支持 `--after`）|
| `al-test3` | 四道工序批量执行器 |
| `al-cmd` | 向桥接发命令并等待终态回报 |
| `al-style-diff` | 只读对比两次编辑差异（用于风格校准）|
| `start-lr-bridge.sh` | 自动点击菜单启动桥接循环 |

---

## 桥接命令契约

Agent 通过 HTTP 与插件通信：

```
Agent ──POST /command──► Bridge（127.0.0.1:8765）◄──GET /next── 插件轮询
                            ▲                                    │
                            └──────GET /result ◄─────────────────┘
```

| 命令 | 参数 | 作用 |
|---|---|---|
| `ping` | — | 连通性检查 |
| `develop` | 友好参数名 | 写基础影调（exposure/contrast/...）|
| `develop_set` | **LR 原生键名** | 写 HSL / 点曲线 / 降噪 / 暗角 / 颗粒 / 裁切 等 |
| `develop_keys` | — | 列出可写键白名单 |
| `optics` | `name` | 镜头矫正 + 去色差 + 自动透视 |
| `reject` | `files` | 批量落 `pick=-1` |
| `keyword` | `files, add, remove` | 增删关键字 |
| `collection` | `list` / `name, files` | 列出或加入收藏夹 |
| `search` | `rating, keywords, filename, flag` | 按条件搜索照片 |
| `view` / `thumbs` | `name, size` | 渲染预览 |
| `probe` | — | 探测本机 SDK 可用 API |

`develop_set` 采用**白名单**约束可写范围（100+ 个已验证键），
超出范围会被明确拒绝并列出原因，**不会静默写坏照片**。

---

## 关键设计（都是踩坑换来的）

### 1. 测量基准必须是原片，不是预览缓存

LR 的预览缓存**已包含当前 develop 设定**。对已修过的照片再测，测到的是
"上一轮改完的结果"，规则于是认为"高光没问题"——实测导致 **89% 的照片
高光压制参数从未被设置**。

> 实测差异：同一张照片，原片 R/G=1.276 / 均值 107，
> 预览缓存 R/G=0.892 / 均值 200 —— **结论完全相反**。

### 2. 写回必须回读自证，不认插件回报

插件的 `ok` 回报可能是假成功（例如写旧键名 `Exposure` 时 LR 会**静默忽略**）。
一律以 catalog 的 `Adobe_imageDevelopSettings` 实际值为准。

### 3. Lightroom 跑的是 Lua 5.1

禁用 `goto` / `::label::` / 位运算符——它们会让整份脚本解析失败，
**插件被 LR 整个禁用**（表现为菜单项凭空消失）。

### 4. VLM 输入必须缩放

把原片全分辨率直接喂 VLM 会让视觉 token 爆炸：实测单张推理 **150–208 秒**，
且 16GB 机器 swap 被写满、任务被拖死。缩到长边 1024 后 **208s → 21s（10×）**，
字段质量不降。测量类判断仍在全分辨率上由 `al-vision` 完成。

### 5. VLM 输出必须无损

曾因解析器过滤而**静默丢弃 13 个子字段**（VLM 返回 35 行、解析后只剩 22 行）。
现在逐行保留 + `[完整度]` 自检。

---

## 已知限制

- **仅适配 macOS**：测量层依赖 macOS Vision / CoreImage。
- **EXIF ISO 未 harvest**：降噪改用 VLM 的「噪点可见性」作为主判据。
- **AI 降噪需手动**：Lightroom 的 AI 降噪无对应 SDK 命令，暂无法自动化。
- **局部蒙版有限**：可通过 `develop_set` 写蒙版参数，但生成蒙版形状仍受限。
- **VLM 语义有噪声**：4B 模型对小图的表情/焦点判断存在波动，因此废片判定
  强制要求「数值 + VLM 双方一致」才落 `pick=-1`。

---

## 性能

在 M5 / 16GB 上实测（Qwen3-VL-4B，长边 1024）：

| 阶段 | 耗时 |
|---|---|
| VLM 单次读图 | ~12–15 s |
| 原片测量 + 规则层 | ~15 s |
| 写回 + 回读 | 1–2 s |
| **每张合计** | **约 32–40 s** |
| **240 张全量** | **约 2.5 小时** |

---

## 插件单测

```bash
luarocks install --tree lua_modules busted
lua_modules/bin/busted
```

覆盖：develop 白名单、关键实现约束、命令面完整性、Lua 5.1 兼容性、递归 JSON 解析。

---

## 项目结构

```
Agent Lightroom Bridge.lrplugin/   Lightroom 插件（Lua）
bridge/server.js                   桥接服务（命令队列 + 状态）
tools/                             Agent 侧工具链（Python / Swift）
plugin/spec/                       插件单元测试
README-LR.md                       开发笔记与 SDK 实证
```

---

## 许可

[Apache License 2.0](LICENSE)

---

## 致谢

- 插件 auto-start 的 `postAsyncTaskWithContext` 修法参考了
  [lightroom-mcp](https://github.com/cpina/lightroom-mcp) 的实践。
- 语义理解使用 [Qwen3-VL](https://github.com/QwenLM/Qwen3-VL)，
  经 [MLX](https://github.com/ml-explore/mlx) 在本机推理。
