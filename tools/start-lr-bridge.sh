#!/bin/bash
# 全自动启动 Lightroom 桥接插件轮询（AX 定位 + CGEvent 点击版）。
#
# ── 为什么需要这个脚本 ──────────────────────────────────────────────
# Lightroom 不会在 App 启动时执行插件的 LrInitPlugin，插件脚本只在被显式触发时
# 运行，因此必须由外部点一次：
#     文件 → 增效工具额外信息 → Agent Lightroom - Start Bridge
#
# ── 为什么用 AX 定位 + CGEvent 点击 ─────────────────────────────────
# LR 自绘菜单对 AppleScript 的 `click` 返回 -1728，对 AXPress 也毫无响应；
# 唯一可行的是 CGEvent 合成事件（agentlr-click）。并且展开子菜单必须用 **悬停**——
# 点击父项会执行动作并关闭菜单。
#
# ⚠️ 2026-09-19 实锤的坑（旧版脚本就是死在这里）：
#   旧版用**硬编码偏移**（父项 +316/+36）点子菜单项，实际会点空；而"点空"是
#   **静默失败**——验证用的是 ping，ping 会被**上一代旧循环**应答，于是脚本报
#   "→ ok"，新代码却从未载入。表现为：文件改了、测试全超时，极难定位。
#   现在改为：AX 读出父项与子菜单各项的**真实坐标** → 悬停父项展开 → 点击标题含
#   "Start Bridge" 的那一项 → 并用 **resultSeq 前进** 作为唯一成功判据
#   （只有新载入的插件脚本才会发 boot 回报，旧循环不会）。
set -uo pipefail

LR="Adobe Lightroom Classic"
DIR="$(cd "$(dirname "$0")" && pwd)"
CLICKER="${AGENT_LIGHTROOM_CLICKER:-$DIR/agentlr-click}"
HEALTH="http://127.0.0.1:8765/health"

os() { perl -e 'alarm 12; exec @ARGV' osascript "$@" 2>/dev/null; }
[ -x "$CLICKER" ] || { echo "✗ 缺少 ${CLICKER}（先编译 agentlr-click.swift）"; exit 1; }

seq_of() { curl -s --max-time 3 "$HEALTH" 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('resultSeq',0))" 2>/dev/null || echo 0; }

seq_before=$(seq_of)
# ⚠️ 2026-09-23 铁律变更：**绝不 activate（不抢前台）**。
# 用户已明确要求纯静默驱动（参照 codex 标准），dsh-cua v2.0 起「点击前先 activate」
# 已作废。实测：AXPress / CGEvent.postToPid 下的菜单操作对后台 app 依然有效，
# 下面的菜单读取与点击都**不需要** Lightroom 处于前台。
# 如果 LR 完全不在前台导致菜单读不到，正确做法是让用户自己切一下，
# 或者改用文件通道（/tmp/al-view.request），**不要 activate**。
# 🔴 实测结论（2026-09-23，务必先读，别浪费一晚）：
#   **静默模式下拉不起插件菜单。** LR 不在前台时，菜单栏 AX 读取稳定返回空
#   （实测连续 5 次全空），因为 LR 只有在成为 active app 时才构建菜单栏项。
#   两者不可兼得：要么抢前台（违反用户铁律），要么这一条重载命令失败。
#
#   因此本脚本的定位是「**一次性重载工具**」：
#     · 默认拒绝运行，并打印下面这段说明；
#     · 只有显式 AGENT_LIGHTROOM_FOREGROUND_OK=1 才真的抢前台执行重载。
#
#   而**日常修图完全不需要它**：bridge 轮询一旦活着就一直在跑
#   （实测 lastSeen 常年 0.5s、resultSeq 持续推进），
#   develop/develop_set/optics/reject 全部走 HTTP，**全程静默、不碰前台**。
#   只有「插件代码变了要重新载入」这一种情况才需要本脚本。
if [ "${AGENT_LIGHTROOM_FOREGROUND_OK:-0}" != "1" ]; then
    cat <<'EOM'
✗ 拒绝执行：静默模式无法重载插件（实测菜单栏 AX 读取对后台 LR 返回空）。

  本脚本只在**插件代码变更、需要重新载入**时用一次，且必须抢前台（LR 的限制）。
  日常修图**不需要**它 —— bridge 轮询活着就一直有效，develop/optics/reject
  全走 HTTP，完全静默。

  确认要重载（会短暂把 Lightroom 切到前台），请运行：
      AGENT_LIGHTROOM_FOREGROUND_OK=1 tools/start-lr-bridge.sh

  先确认 bridge 是否还活着（活着就不用重载）：
      curl -s http://127.0.0.1:8765/health
EOM
    exit 2
fi
echo "1) 准备 Lightroom（resultSeq=${seq_before}）"
echo "   ⚠️ 用户显式允许抢前台（AGENT_LIGHTROOM_FOREGROUND_OK=1），开始重载"
os -e "tell application \"$LR\" to activate" >/dev/null
sleep 1

echo "2) 打开「文件」菜单并读「增效工具额外信息」坐标（最多重试 5 次）"
# 说明：System Events 的 AX 读取偶发超时（返回空）或菜单尚未展开（返回折叠哨兵
# "0, 956"）——这两者都不是「菜单被裁剪」。必须重试并区分，否则会误报成导入界面问题。
PX=""; PY=""
for attempt in 1 2 3 4 5; do
    FX=$(os -e "tell application \"System Events\" to tell process \"$LR\" to get position of menu bar item \"文件\" of menu bar 1" | cut -d, -f1 | tr -d ' ')
    if [ -z "$FX" ]; then sleep 1; continue; fi
    "$CLICKER" click $((FX + 10)) 12 >/dev/null 2>&1
    sleep 2
    P=$(os -e "tell application \"System Events\" to tell process \"$LR\" to get position of menu item \"增效工具额外信息\" of menu 1 of menu bar item \"文件\" of menu bar 1")
    case "$P" in
        "")               echo "   第 ${attempt} 次：AX 读取超时（空），重试"; sleep 1; continue ;;
        "0, 956"|"0,956") echo "   第 ${attempt} 次：菜单未展开，重试"; sleep 1; continue ;;
    esac
    PX=$(echo "$P" | cut -d, -f1 | tr -d ' '); PY=$(echo "$P" | cut -d, -f2 | tr -d ' ')
    break
done
if [ -z "$PX" ] || [ -z "$PY" ]; then
    echo "   ✗ 5 次都没读到该菜单项坐标（超时=System Events 慢，可重跑；未展开=LR 可能停在导入界面）"
    exit 1
fi
echo "   父项 @${PX},${PY}"

echo "5) 悬停父项展开子菜单，并读出各项真实坐标"
# ⚠️ LR 自绘菜单的 AX 位置在部分状态下 x 报 0（实测 "0,407"），直接用 x 会把指针
# 移到菜单外 → 子菜单不展开；且**子菜单未展开时 AX 仍会返回子项**（坐标为折叠哨兵
# 0,956），所以必须按"坐标是否等于哨兵"判定展开成功，而不是看返回是否为空。
HOVER_X=$((PX + 40))
if [ "${PX:-0}" -le 1 ]; then
    HOVER_X=$((FX + 50))
    echo "   （父项 x 读了 0，改用「文件」菜单左边缘 ${FX} + 50 = ${HOVER_X}）"
fi

read_submenu() {
    os -e "
tell application \"System Events\" to tell process \"$LR\"
  set out to \"\"
  try
    repeat with mi in (menu items of menu 1 of menu item \"增效工具额外信息\" of menu 1 of menu bar item \"文件\" of menu bar 1)
      set nm to (name of mi)
      if nm is not missing value then
        set ps to (position of mi)
        set sz to (size of mi)
        set out to out & nm & \"|\" & (item 1 of ps) & \",\" & (item 2 of ps) & \"|\" & (item 1 of sz) & \",\" & (item 2 of sz) & linefeed
      end if
    end repeat
  end try
  return out
end tell"
}

ITEMS=""
for attempt in 1 2 3 4; do
    # 两段式移动：先到项上，再微移 3px，确保产生 mouse-moved 事件（一次跳变有时不触发 submenu）
    "$CLICKER" hover "$HOVER_X" $((PY + 12)) >/dev/null 2>&1
    sleep 1
    "$CLICKER" hover $((HOVER_X + 3)) $((PY + 13)) >/dev/null 2>&1
    sleep 1
    ITEMS=$(read_submenu)
    # 展开判据：存在坐标不是 0,956 的子项
    if echo "$ITEMS" | grep -qv ",956|"; then
        echo "   子菜单已展开（第 ${attempt} 次尝试）"
        break
    fi
    echo "   第 ${attempt} 次：子菜单未展开（返回折叠哨兵 0,956），重试"
done

LINE=$(echo "$ITEMS" | grep -i "Start Bridge" | head -1)
[ -z "$LINE" ] && {
    echo "   ✗ 子菜单里找不到 Start Bridge。子菜单实际内容："
    echo "$ITEMS" | sed 's/^/     /'
    echo "   提示：若这里只有其它插件的项，说明本插件的 Info.lua 菜单声明没注册成功"
    echo "        （历史上 LrExportMenuItems 曾写成单个表而非数组 → 从未注册）。"
    exit 1
}
NAME=$(echo "$LINE" | cut -d'|' -f1)
COORD=$(echo "$LINE" | cut -d'|' -f2); SIZE=$(echo "$LINE" | cut -d'|' -f3)
IX=$(echo "$COORD" | cut -d, -f1 | tr -d ' '); IY=$(echo "$COORD" | cut -d, -f2 | tr -d ' ')
IW=$(echo "$SIZE" | cut -d, -f1 | tr -d ' '); IH=$(echo "$SIZE" | cut -d, -f2 | tr -d ' ')
CX=$((IX + IW / 2)); CY=$((IY + IH / 2))
echo "6) 点击「${NAME}」（真实坐标 @${CX},${CY}）"
"$CLICKER" click "$CX" "$CY" >/dev/null
sleep 3

echo "7) 验证新循环是否真的载入（resultSeq 必须前进；旧循环应答不算数）"
for _ in $(seq 1 10); do
    seq_now=$(seq_of)
    if [ "${seq_now:-0}" -gt "${seq_before:-0}" ]; then
        echo "   ✓ resultSeq ${seq_before} → $seq_now"
        curl -s --max-time 3 "$HEALTH" | python3 -c "
import sys,json
d=json.load(sys.stdin); r=d.get('lastResult') or {}
print('   →',r.get('status'),'/',r.get('message'))
"
        exit 0
    fi
    sleep 1
done
echo "   ✗ 没有新回报：点击没生效，插件新代码未载入"
exit 1
