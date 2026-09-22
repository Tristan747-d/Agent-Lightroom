# Agent-Lightroom
让 Agent 真正"看懂"照片并驱动 Lightroom Classic 完成批量的审片与后期——先用 macOS Vision 做确定性测量、用本地 VLM 做语义判断，再由可解释的规则层出参数，经自研桥接插件写回 LR 并回读自证，最终以"VLM 看前期 → 套配方 → VLM 复查 → 微调"四道工序逐张闭环，全部本机离线、零云端依赖。
