# Lightroom Classic 接入

## 架构

```
前端（web 或 Xcode App，人在环）
   │  HTTP POST http://127.0.0.1:8765/command
   ▼
Bridge 服务（bridge/server.js，命令队列 + 状态）   ◀── 插件每 1s GET /next 取命令
   ▲  GET /health、GET /state（含 culling 回灌）       └── 插件执行后 GET /result 回报
   │
Lightroom Classic 插件（Agent Lightroom Bridge.lrplugin，Lua）
```

原片**不上传**，只走本机环回地址；Agent 负责执行，审片与最终确认由人完成。

## 启动

```bash
node bridge/server.js
```

在 Lightroom Classic 中打开 Plug-in Manager，选择 `Agent Lightroom Bridge.lrplugin` 目录并启用插件，然后在 Library / Export 菜单选择 **Agent Lightroom - Start Bridge**。

网页工作台通过 `http://127.0.0.1:8765` 发送本机命令；Xcode App 同样连该地址并在线时拉取 `snapshot` 同步选片状态。

## 让 agent「看见」照片（读图引擎）

agent 要审片/写调色建议，前提是**它自己能看图**。两条路已实现，优先用第 ①条：

### ① 预览缓存路（默认，零插件依赖，**已验证**）

Lightroom 会把每张照片的**渲染结果**（含 develop 设定）写进
`<catalog> Previews.lrdata/<X>/<XXXX>/<UUID>-<hash>_<尺寸>`，这些文件**本身就是标准 JPEG**
（`FFD8…FFD9`），拷出来 agent 就能看——**不是原文件拷贝**，天然满足
「选片预览必须是 Lr 内基础编辑完成后的预览」。

映射关系（踩过坑，务必按这个来）：

```
文件名  →  AgLibraryFile.idx_filename
UUID   →  AgLibraryFile.id_global     ← 预览文件名前缀就是它
          （不是 Adobe_images.id_global！用后者查会「找不到预览」）
尺寸   →  文件名末尾 _320 / _1024 / _2048 …（取最大）
```

```bash
tools/al-see                          # 目录里最新一张 → /tmp/agent-lightroom-view.jpg
tools/al-see "DSC01234.ARW"           # 指定文件名
tools/al-see --catalog <x.lrcat> --name y.heic
```

输出一行 JSON（`file/name/uuid/source/width/height/bytes`），随后 agent 直接读
`file` 指向的 JPEG 即可。实测 0.12s，HEIC 也支持（LR 已解码）。

> ⚠️ 前提：该照片在 LR 里**生成过预览**。刚 `addPhoto` 加进目录、还没进过网格的照片
> 可能没有预览文件（此时报「预览缓存里没有…」，回退插件通道）。

### ② 插件文件通道（备路，需插件新代码已载入）

`/tmp/al-view.request`（第1行 token / 第2行 size / 第3行 文件名）→ 插件渲染 →
`/tmp/al-view.response`。该通道**绕开 `/next` 命令队列**，因为队列会被
**上一代旧轮询循环**抢走命令（LR 里每点一次 Start Bridge 就多起一个循环、旧循环不会退出，
旧代码不认识新命令却会应答，造成假失败）。渲染优先级：`catalog:exportJpeg`（本机为 nil）→
`photo:requestJpegThumbnail`（本机可用）→ 回退原片路径。

## 命令 → 状态通道（为什么要有 tools/al-cmd）

```bash
tools/al-cmd '{"type":"view","name":"x.heic"}' --expect view,error
```

bridge 的 `/health` 里带**单调递增的 `resultSeq`**：客户端据此判断「这是一次新回报」。
只比较 `status/message` 会在**重复的相同回报**上失灵（连发两次 ping 结果一样 → 假超时）。
`al-cmd` 还支持 `--expect`：终态不符预期就重发，用来绕开旧轮询循环的抢占。

## 插件重载（tools/start-lr-bridge.sh）

LR 不会在启动时自动跑插件的轮询循环，必须点一次
`文件 → 增效工具额外信息 → Agent Lightroom - Start Bridge`。该脚本全自动完成，
并且**只认 `resultSeq` 前进**作为成功判据——用 ping 验证会被上一代旧循环应答，
从而产生「脚本报成功、新代码其实没载入」的假成功（本项目实际踩过，排查了很久）。

另注意：**LR 停在导入界面时「文件」菜单会被裁剪**（没有「增效工具额外信息」），
此时须先回到图库/修改照片模块。

## 命令契约（前端 → Bridge → 插件）

| 命令 | 字段 | 插件行为 |
| --- | --- | --- |
| `ping` | — | 回报 `ok` |
| `snapshot` | — | 回报目录全部照片的 `fileName\|flag\|拍摄者\|焦距\|时间\|光圈\|快门\|ISO` |
| `import` | `source` | 有 `source` 直接 `triggerImportUI(source)`；否则弹窗选目录 |
| `decision` | `value=keep\|reject\|master` | 设当前片 `pickStatus`（master 额外 rating=5） |
| `adjust` | `exposure,contrast,temperature,tint` | `applyDevelopSettings`（exposure/contrast 已在插件侧 `/20`） |
| `view` | `name,size` | 渲染指定/当前照片为 JPEG 交 agent 读图 |
| `add` | `files`（`;` 分隔） | `catalog:addPhoto`，把文件直接加进目录（喂测试素材，不走导入 UI） |
| `develop` | `name,exposure,contrast` | 按**文件名**定位并写 develop（不依赖 UI 选中态） |
| `probe` | `source` | 探测本机 SDK 可用 API（含 io/写文件能力自检） |
| `routine` | `source` | 固定流程：Upright=Auto 批量落库 + 回读验证 |
| `thumbs` | `source` | 批量渲染 512px 预览到 `/tmp/al-thumbs/` |
| `sync` | `count` | 把当前片 develop 设定同步到选中的目标片 |
| `export` | `count,path` | 确认通道（最终交付仍需在 Lightroom 内导出） |

## 本机 LR 15.5 SDK 实测（勿再假设）

`applyAutoTone` **不存在(nil)** → 「Cmd+U 自动调整」只能走 UI；
`cat.exportJpeg`、`cat.getMultipleSelectedPhotos`、`LrFileUtils.writeFile` 均为 nil；
可用的是 `applyDevelopSettings` / `getDevelopSettings` / `requestJpegThumbnail` /
`getRawMetadata('path')` / `catalog:addPhoto` / `io.open`。
Upright 自动 = develop 设置 `PerspectiveUpright = 1`。
插件轮询循环必须用 `LrTasks.pcall` 包住单条 `handle()`，否则任一 SDK 缺失方法会抛错打死整个循环。


## 选片回灌契约（插件 → Bridge → 前端）

- 插件目录快照走 `GET /result?status=catalog&message=name\|flag;name\|flag…`
- Bridge 同时兼容旧式 `photos=name\|flag;…`，二者都解析进 `state.culling`
- 前端 `GET /state` 读 `culling[]` 把 `reject/select` 回灌到胶片条
  （Xcode App 的 `refreshCullingState` 依赖这一链路，务必保持 `127.0.0.1:8765` 在线）

## 当前已接入

- 当前选中照片读取
- Pick 状态：保留、淘汰、主片
- Develop：曝光、对比度、色温和色调
- 目录消隐结果回灌（snapshot）
- 导出命令确认通道

后续可把导入队列、相似组和 Lightroom 原生导出预设继续映射到同一桥接协议。

---

# 算法：让 LLM 看懂照片并给出后期参数

## 分层（每层可独立替换、独立验证）

| 层 | 做什么 | 实现 | 为什么这样分 |
| --- | --- | --- | --- |
| L0 取像 | 拿到「LR 里现在的样子」 | `tools/al-see` | 后期必须基于**修图后**的渲染，不是原片 |
| L1a 数值感知 | 精确测量 | `tools/al-vision`（macOS Vision + CoreImage，本机离线） | 溢出百分比、锐度、地平线角度这些**模型测不准**，必须由确定性算法给 |
| L1b 语义感知 | 看懂内容 | 本地 VLM（Qwen-VL）经 `tools/al-vlm-server` | 「这是什么 / 该不该留 / 风格意图」只有模型能给 |
| L2 决策 | 出参数与保/弃 | `tools/al-tune`（阈值规则，逐条可解释） | 数值必须来自**规则**：小模型给数值会瞎编，且无法审计 |
| L3 执行 | 写回 Lightroom | bridge `develop` / `adjust` | 复用既有插件通道 |
| L4 闭环 | 写回后再读一次预览、对比直方图 | 再跑一次 `al-see` + `al-vision` | 测量→动作→再测量，才算闭环（待接入） |

## 三条关键设计

1. **数值与语义分离**：`al-vision` 给数字，VLM 给内容理解，规则表把数字变成 Lightroom 参数。
   这样即使只有纯文本 LLM（本机 gm 网关 Llama-3.1-8B）也能「看懂并后期」——`al-analyze --llm` 已实测。
2. **VLM 只能做有界修正**：白名单参数（曝光/对比/高光/阴影/白/黑/鲜艳度/饱和度/清晰度/纹理/去朦胧）
   + 每项增量绝对值 ≤ 15，越界即丢弃并记入 `param_tweaks_rejected`。防止模型把照片调坏。
3. **场景守则约束数值**：夜景/暗调（标签含 night/dark 或中间调均值 < 25）自动限幅
   （阴影 ≤ 15、不抬黑位）。这条是**验证时发现的真实缺陷**：规则把夜景 80% 的死黑当缺陷，
   阴影一路抬到 +60，模拟验证显示会把夜色抬灰并推高溢出。

## 阈值表（`tools/al-tune` 内集中定义，按审美改）

| 判据 | 阈值 | 触发动作 |
| --- | --- | --- |
| 中间调均值 | < 45 / > 160 | 曝光 ±（最多 +1.2 / −1.0 EV） |
| 高光溢出 | > 1.0% | 压高光（>3% 再收白色色阶） |
| 暗部死黑 | > 2.0% | 提阴影（>8% 再抬黑色色阶） |
| P95 / P5 | < 180 / > 40 | 补白场 / 压黑场 |
| 反差 RMS | < 40 / > 72 | 加 / 减对比 |
| 饱和度 | < 0.12 / > 0.45 | ±鲜艳度（优先于饱和度，护肤色） |
| 白平衡 R/G、B/G | 偏离 1 超 0.06 | 色调 / 色温**增量**修正 |
| 锐度（拉普拉斯方差） | < 30、30–120 | 糊片→排除候选 / 补清晰度+质感 |
| 人脸区域锐度 | < 25 | 主体失焦→排除候选 |
| 眼睛纵横比 | < 0.18 | 疑似闭眼→提示 |
| 地平线倾角 | > 0.5° | 自动拉直 |
| 美学 `is_utility` 或文本 ≥6 行且覆盖 >5% | — | 判为截图/文档：**排除且跳过修图** |
| 主体 vs 背景亮度 | 主体暗 25+ 且确实分割出人物 | 建议局部压暗背景（不做全局牺牲） |

## 用法

```bash
tools/al-analyze --latest                 # 目录里最新一张，出人读报告
tools/al-analyze photo.jpg --json         # 机器可读（含 digest 与 decision）
tools/al-analyze photo.jpg --llm          # 追加文本 LLM 语义层（gm 网关）
tools/al-analyze photo.jpg --vlm          # 追加本地 VLM 看图（自动探测后端）
tools/al-vlm-check photo.jpg              # 一键：起 VLM 服务 + 全链路自检
```

VLM 后端自动探测顺序：自研 `al-vlm-server`（8321）→ LM Studio（1234）→ Ollama（11434）；
后两者走 OpenAI 兼容口，`image_url` 用 data URI 传图（过大时先 `sips` 缩到 1280）。

## 已验证 / 未验证

* 已实测：三张真实照片（夜景人像）给出合理解释与参数；模拟器验证方向正确
  （中间调 15 → 71、死黑 80% → 0%、对比 39 → 42）——**近似模拟，不等于 LR 实测**。
* 未实测：VLM 语义层（Qwen-VL 尚在下载）；L4 闭环校验（写回 LR 后再读预览对比）。

