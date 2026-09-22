-- 新增"操作便利"命令的规格测试。
-- 这些命令全部走 File > /next 通道，格式为 { type=..., ... }。
-- 本文件校验：命令已注册、参数校验到位、回报格式符合既有约定（report(status,msg)）。

local helper = require 'spec.spec_helper'

local function readSource()
    local candidates = {
        "Agent Lightroom Bridge.lrplugin/Bridge.lua",
        "plugin/Agent Lightroom Bridge.lrplugin/Bridge.lua",
    }
    for _, p in ipairs(candidates) do
        local f = io.open(p, "rb")
        if f then local s = f:read("*a"); f:close(); return s end
    end
    error("Bridge.lua not found")
end

local src = readSource()

local NEW_COMMANDS = {
    { name = "develop_set",  fn = "developSet",     desc = "按 LR 原生键名直写（HSL/曲线/降噪…）" },
    { name = "develop_keys", fn = "listDevelopKeys", desc = "列出可用键白名单" },
    { name = "keyword",      fn = "editKeywords",    desc = "加/删关键字" },
    { name = "collection",   fn = "collections",     desc = "列收藏夹 / 加入收藏夹" },
    { name = "search",       fn = "searchPhotos",    desc = "按条件搜照片" },
    { name = "optics",       fn = "correctOptics",   desc = "镜头矫正+去色差+自动透视" },
    { name = "reject",       fn = "rejectPhotos",    desc = "批量落 pick=-1" },
}

describe("操作便利命令已注册", function()
    for _, c in ipairs(NEW_COMMANDS) do
        it("command.type == '" .. c.name .. "' (" .. c.desc .. ")", function()
            assert.is_truthy(src:find("command.type == '" .. c.name .. "'", 1, true),
                "dispatch missing for " .. c.name)
            assert.is_truthy(src:find("local function " .. c.fn, 1, true),
                "implementation missing: " .. c.fn)
        end)
    end
end)

describe("命令实现约束（防复发）", function()
    it("关键字：createKeyword 先去重（同一事务内不幂等）", function()
        local body = src:match("local function editKeywords.-\nend\n")
        assert.is_truthy(body, "editKeywords not found")
        assert.is_truthy(body:find("seen", 1, true),
            "必须去重：createKeyword 在同一写事务内不幂等（参考实现明确提示）")
    end)

    it("收藏夹：用 getChildCollections 递归，且不假设返回非 nil", function()
        local body = src:match("local function collections.-\nend\n")
        assert.is_truthy(body, "collections not found")
        assert.is_truthy(body:find("getChildCollections", 1, true))
        assert.is_truthy(body:find("LrTasks.pcall", 1, true),
            "getChildCollections 可能失败，需 pcall 保护")
    end)

    it("搜索：无条件下退化为 getAllPhotos（不能返回空）", function()
        local body = src:match("local function searchPhotos.-\nend\n")
        assert.is_truthy(body, "searchPhotos not found")
        assert.is_truthy(body:find("getAllPhotos", 1, true),
            "无条件搜索时应列出全部，而不是报错或空")
        assert.is_truthy(body:find("findPhotos", 1, true))
    end)

    it("所有新命令都通过 report(...) 回报（沿用既有通道契约）", function()
        for _, fn in ipairs({ "developSet", "editKeywords", "collections", "searchPhotos" }) do
            local body = src:match("local function " .. fn .. ".-\nend\n")
            assert.is_truthy(body:find("report(", 1, true), fn .. " 未使用 report 回报")
        end
    end)

    it("搜索条件用 LR 原生契约（combine/criteria/operation）", function()
        local body = src:match("local function searchPhotos.-\nend\n")
        -- 参考实现规定：desc 首项必须是 { combine = "intersect" }；
        -- 关键字 criteria 是**复数 keywords** + operation="all"（写成单数 LR 不认）
        assert.is_truthy(body:find("combine = 'intersect'", 1, true),
            "缺少 combine=intersect，LR 可能不接受该 searchDesc")
        assert.is_truthy(body:find("criteria = 'keywords'", 1, true),
            "criteria 必须是复数 keywords")
        assert.is_truthy(body:find("operation = 'all'", 1, true))
        assert.is_truthy(body:find("criteria = 'filename'", 1, true))
        assert.is_truthy(body:find("operation = 'any'", 1, true))
    end)

    it("flag（pick/reject）在结果侧过滤（LR 无稳定 flag criteria）", function()
        local body = src:match("local function searchPhotos.-\nend\n")
        assert.is_truthy(body:find("pickStatus", 1, true),
            "flag 过滤应读 pickStatus 在结果侧筛，而非伪造 criteria")
    end)
end)

describe("不改动既有语义与风格（回归护栏）", function()
    it("develop（友好名）与 develop_set（原生名）并存，互不替换", function()
        assert.is_truthy(src:find("command.type == 'develop'", 1, true))
        assert.is_truthy(src:find("command.type == 'develop_set'", 1, true))
    end)

    it("没有引入 autoTone / 应用预设这类会覆盖用户意图的**调用**", function()
        -- 项目铁律：数值来自规则，VLM 只做有界修正；不得引入"一键自动风格"。
        -- 注意：只看**实际调用**（冒号调用形式），不看注释/探针里的类型查询——
        -- 源码里有 `type(p.applyAutoTone)` 这种存在性探测，那是文档不是调用。
        assert.is_nil(src:find(":applyAutoTone(", 1, true),
            "不得调用 applyAutoTone（本机为 nil，且会覆盖规则层意图）")
        assert.is_nil(src:find(":applyDevelopPreset(", 1, true),
            "不得应用预设：会绕过规则的数值决策")
    end)
end)
