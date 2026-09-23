#!/usr/bin/env python3
"""al-fast 解析层单测（离线，不需 GPU/Lightroom）。

为什么单独测解析层：al-fast 的**全部质量风险都集中在这里**——
行式解析会静默丢字段、位置式解析会静默串位。这两类失效都不会报错，
只会让参数悄悄算错。所以它们必须有断言兜住。

运行: python3 plugin/spec/test_al_fast_parse.py
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, "..", "..", "tools", "al-fast")
ns = {"__file__": TOOL}
src = open(TOOL).read()
exec(compile(src.split("def main(")[0], "al-fast", "exec"), ns)

PASS, FAIL = [], []


def check(name, cond, detail=""):
    (PASS if cond else FAIL).append(name)
    print(("  ✓ " if cond else "  ✗ ") + name + (f"   {detail}" if detail and not cond else ""))


print("== 1) 位置式顺序与主字段表严格对齐（错位是位置式最危险的失效）==")
check("before 前 24 项 == BEFORE_KEYS",
      ns["POS_ORDER_BEFORE"][:len(ns["BEFORE_KEYS"])] == ns["BEFORE_KEYS"])
check("after 前 21 项 == AFTER_KEYS",
      ns["POS_ORDER_AFTER"][:len(ns["AFTER_KEYS"])] == ns["AFTER_KEYS"])
check("before 无重复字段", len(set(ns["POS_ORDER_BEFORE"])) == len(ns["POS_ORDER_BEFORE"]))
check("after 无重复字段", len(set(ns["POS_ORDER_AFTER"])) == len(ns["POS_ORDER_AFTER"]))
check("提示行数 == 顺序长度",
      ns["PROMPT_BEFORE_POS"].count("\n") >= len(ns["POS_ORDER_BEFORE"]))

print("== 2) 行式解析：子字段归父、不覆盖、原始行全留 ==")
raw = """主题: 活动记录
构图: 居中
问题: 背景干扰
曝光: 适中
高光: 安全
位置: 天花板
阴影: 略沉
位置: 座椅"""
f, subs, lines = ns["parse_lossless"](raw, ns["BEFORE_KEYS"])
check("主字段解析正确", f.get("主题") == "活动记录" and f.get("构图") == "居中")
check("同名子字段不互相覆盖（位置出现两次）",
      len([1 for k, _ in subs["高光"] if k == "位置"]) == 1
      and len([1 for k, _ in subs["阴影"] if k == "位置"]) == 1)
check("原始行数全保留（无损）", len(lines) == len(raw.splitlines()))

print("== 3) 子字段取值助手：修掉「问题 恒为空」的继承 bug ==")
check("能从子字段取到 问题",
      ns["_sub_value"](subs, "构图", "问题") == "背景干扰")
check("取不到时返回空串而不是 None",
      ns["_sub_value"](subs, "构图", "不存在的键") == "")
check("父字段不存在时也不炸",
      ns["_sub_value"](subs, "没有这个父字段", "问题") == "")

print("== 4) 位置式可信度校验：串位必须被拦下 ==")
good = dict(zip(ns["BEFORE_KEYS"],
                ["活动记录", "JPEG直出", "学生", "中上中", "主体比背景亮", "居中", "内容",
                 "适中", "安全", "略沉", "偏高", "正常", "准确", "多人合影", "严肃",
                 "自然", "主体清晰", "轻微", "是", "横平竖直", "无", "否", "均衡", "调白平衡"]))
ok, bad = ns["positional_trustworthy"](good)
check("合法取值 → 可信", ok, f"bad={bad}")

# 复现真实事故：值整体下移一位（构图问题 插队）
shifted = dict(zip(ns["BEFORE_KEYS"],
                   ["活动记录", "JPEG直出", "学生", "中上中", "居中", "无", "内容",
                    "适中", "安全", "略沉", "偏高", "正常", "准确", "多人合影", "严肃",
                    "自然", "主体清晰", "轻微", "是", "横平竖直", "无", "否", "均衡", "调白平衡"]))
ok2, bad2 = ns["positional_trustworthy"](shifted)
check("串位（主体明暗=居中）→ 判为不可信", not ok2, f"bad={bad2}")
check("并指出越界字段", any("主体明暗" in b for b in bad2), f"bad={bad2}")

print("== 5) 位置式解析：序号/字段名污染应被剥掉 ==")
messy = "1. 活动记录\n主题: JPEG直出\n- 学生\n4、中上中"
pf, pl = ns["parse_positional"](messy, ("主题", "图片类型", "主体", "主体位置"))
check("剥掉序号与字段名",
      pf["主题"] == "活动记录" and pf["图片类型"] == "JPEG直出"
      and pf["主体"] == "学生" and pf["主体位置"] == "中上中", str(pf))

print("== 6) 回读键映射表自洽 ==")
lm = ns["LR_KEY"]
check("exposure 映射到现代键 Exposure2012", lm["exposure"] == "Exposure2012")
check("tint 映射到 IncrementalTint", lm["tint"] == "IncrementalTint")
check("PLAIN_MAP 与 LR_KEY 双向一致",
      all(lm[v] == k for k, v in ns["PLAIN_MAP"].items() if v in lm))

print("== 7) 质量护栏：生产路径必须是「全字段提示」（lean 实测降质，不得成为默认）==")
import re
main_src = src.split("def main(")[1]
check("默认（不传 --lean）走全字段 PROMPT_BEFORE",
      "PROMPT_BEFORE_LEAN if args.lean else PROMPT_BEFORE" in main_src)
check("默认（不传 --lean）走全字段 PROMPT_AFTER",
      "PROMPT_AFTER_LEAN if args.lean else PROMPT_AFTER" in main_src)
check("--lean 的 help 明确标注降质/生产禁用",
      "降低语义质量" in src and "生产禁用" in src)
check("启用 --lean 时运行时打印告警",
      "--lean 已启用" in main_src)
check("lean 提示覆盖全部 24 个 before 主字段（即便启用也不许缺字段）",
      all(k + ":" in ns["PROMPT_BEFORE_LEAN"] for k in ns["BEFORE_KEYS"]))
check("lean 提示覆盖全部 21 个 after 主字段",
      all(k + ":" in ns["PROMPT_AFTER_LEAN"] for k in ns["AFTER_KEYS"]))
check("全字段提示覆盖全部主字段",
      all(k + ":" in ns["PROMPT_BEFORE"] for k in ns["BEFORE_KEYS"])
      and all(k + ":" in ns["PROMPT_AFTER"] for k in ns["AFTER_KEYS"]))
check("存在字段完整度自检（missing 会被记录）",
      "missing1" in main_src and "missing3" in main_src)
check("写着「脚手架」注释，防止后人再次删子字段",
      "脚手架" in src)

print(f"\n结果: {len(PASS)} 通过, {len(FAIL)} 失败")
sys.exit(1 if FAIL else 0)
