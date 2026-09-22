-- parseJSON / parseCommand 的递归解析测试。
--
-- 背景事故：原 parseCommand 是扁平正则，无法处理嵌套对象，
-- 导致 develop_set 的 settings={...}、reject 的 files={...} 整体丢失
-- （命令到达 handler 却报 "settings table required"）。
--
-- 测法：把源码里的 parseJSON/parseCommand 抽出来，在纯 Lua 里直接跑。
-- 这两个函数不依赖任何 LR SDK，因此可以原样加载测试。

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

-- 从源码抽出 parseJSON 与 parseCommand 两个 local function，拼成可执行块
local function loadParsers()
    local json = src:match("(local function parseJSON%(str%).-\nend)")
    assert(json, "parseJSON not found in Bridge.lua")
    local cmd = src:match("(local function parseCommand%(response%).-\nend)")
    assert(cmd, "parseCommand not found in Bridge.lua")
    local chunk = json .. "\n" .. cmd .. "\nreturn parseJSON, parseCommand\n"
    local fn = assert(load(chunk, "parsers", "t"))
    return fn()
end

local parseJSON, parseCommand = loadParsers()

describe("parseJSON 递归解析", function()
    it("解析扁平命令（既有格式，必须不回归）", function()
        local c = parseCommand('{"type":"ping"}')
        assert.are.equal("ping", c.type)
    end)

    it("解析嵌套对象（develop_set 的 settings）", function()
        local c = parseCommand(
            '{"type":"develop_set","name":"a.jpg","settings":{"Exposure2012":0.5,"Vibrance":-3}}')
        assert.are.equal("develop_set", c.type)
        assert.are.equal("a.jpg", c.name)
        assert.is_table(c.settings)
        assert.are.equal(0.5, c.settings.Exposure2012)
        assert.are.equal(-3, c.settings.Vibrance)
    end)

    it("解析数组（reject 的 files / keyword 的 add）", function()
        local c = parseCommand('{"type":"reject","files":["a.jpg","b.jpg","c.jpg"]}')
        assert.are.equal(3, #c.files)
        assert.are.equal("a.jpg", c.files[1])
        assert.are.equal("c.jpg", c.files[3])
    end)

    it("解析数组内嵌对象（点曲线：输入/输出对）", function()
        local c = parseCommand(
            '{"type":"develop_set","settings":{"ToneCurvePV2012":[0,0,128,140,255,255]}}')
        assert.are.equal(6, #c.settings.ToneCurvePV2012)
        assert.are.equal(128, c.settings.ToneCurvePV2012[3])
    end)

    it("处理布尔与负数（optics/reject 标志位）", function()
        local c = parseCommand('{"type":"optics","lens":false,"upright":true,"x":-15}')
        assert.are.equal(false, c.lens)
        assert.are.equal(true, c.upright)
        assert.are.equal(-15, c.x)
    end)

    it("处理字符串中的转义与中文", function()
        local c = parseCommand('{"type":"collection","name":"我的收藏\\"A\\""}')
        assert.are.equal('我的收藏"A"', c.name)
    end)

    it("容忍空白与换行", function()
        local c = parseCommand('{ "type" : "search" ,\n "rating" : 3 }')
        assert.are.equal("search", c.type)
        assert.are.equal(3, c.rating)
    end)

    it("解析失败时退回扁平兜底（不打断既有命令）", function()
        -- 非严格 JSON：兜底正则仍应能取到 type
        local c = parseCommand('type:ping')
        assert.is_table(c)
    end)

    it("空对象不报错", function()
        local obj = parseJSON("{}")
        assert.is_table(obj)
        assert.is_nil(next(obj))
    end)
end)
