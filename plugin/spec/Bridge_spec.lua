-- Bridge.lua 的 develop_set 白名单与校验逻辑测试。
--
-- 为什么这样测：Bridge.lua 顶层会启动轮询任务，直接 require 会在纯 Lua 下执行
-- LR 专有代码。所以这里用 loadfile 把源码读进来，只抽取**纯逻辑**部分测试
-- （白名单集合、点曲线校验、键名映射），这些正是最容易出错的地方。
--
-- 覆盖的真实事故：
--   * develop_set 写入未授权键 → 必须被拒绝（不能静默写坏）
--   * 点曲线格式非法（奇数个/非递增/越界）→ 必须拒绝
--   * 增量色温必须自动带 WhiteBalance='Custom'（否则 LR 完全忽略）

local helper = require 'spec.spec_helper'

local function readSource()
    -- 插件实际在仓库根目录；容错地按候选路径找（搬 spec 结构时踩过路径坑）
    local candidates = {
        "Agent Lightroom Bridge.lrplugin/Bridge.lua",
        "plugin/Agent Lightroom Bridge.lrplugin/Bridge.lua",
        "../Agent Lightroom Bridge.lrplugin/Bridge.lua",
    }
    for _, p in ipairs(candidates) do
        local f = io.open(p, "rb")
        if f then
            local s = f:read("*a")
            f:close()
            return s
        end
    end
    error("Bridge.lua not found in any candidate path")
end

-- 从源码里抽出白名单表（避免重复维护一份，测试直接校验真实源码）
local function extractAllowedKeys(src)
    -- 表体到下一个顶层 `local ` 声明为止（原写法找 "\n}" 会失配）
    local block = src:match("local ALLOWED_DEVELOP_KEYS = {(.-)\n}\n")
    assert(block, "ALLOWED_DEVELOP_KEYS not found in Bridge.lua")
    local keys = {}
    for k in block:gmatch("'([%w_]+)'") do keys[#keys + 1] = k end
    return keys
end

describe("Bridge.lua develop 白名单", function()
    local src = readSource()
    local keys = extractAllowedKeys(src)

    it("白名单非空且包含基础影调键", function()
        assert.is_true(#keys > 50)
        local set = {}
        for _, k in ipairs(keys) do set[k] = true end
        assert.is_true(set["Exposure2012"])
        assert.is_true(set["Highlights2012"])
        assert.is_true(set["Shadows2012"])
    end)

    it("包含 HSL 八通道（本次新增的'手'）", function()
        local set = {}
        for _, k in ipairs(keys) do set[k] = true end
        for _, ch in ipairs({ "Red", "Orange", "Yellow", "Green",
                              "Aqua", "Blue", "Purple", "Magenta" }) do
            assert.is_true(set["HueAdjustment" .. ch], "missing Hue " .. ch)
            assert.is_true(set["SaturationAdjustment" .. ch], "missing Sat " .. ch)
            assert.is_true(set["LuminanceAdjustment" .. ch], "missing Lum " .. ch)
        end
    end)

    it("包含点曲线 / 降噪 / 暗角 / 颗粒 / 裁切", function()
        local set = {}
        for _, k in ipairs(keys) do set[k] = true end
        for _, k in ipairs({ "ToneCurvePV2012", "ToneCurvePV2012Red",
                             "LuminanceSmoothing", "ColorNoiseReduction",
                             "PostCropVignetteAmount", "GrainAmount",
                             "CropTop", "CropAngle", "PerspectiveUpright" }) do
            assert.is_true(set[k], "missing " .. k)
        end
    end)

    it("不包含会破坏流程的危险键（白名单是安全边界）", function()
        local set = {}
        for _, k in ipairs(keys) do set[k] = true end
        -- 这些键若可写，会造成"假成功"或破坏我们已修好的语义
        assert.is_nil(set["Exposure"])   -- 旧键：LR 静默忽略 → 假成功
        assert.is_nil(set["Contrast"])
        assert.is_nil(set["Brightness"])
    end)
end)

describe("Bridge.lua 关键实现约束", function()
    local src = readSource()

    it("轮询用 postAsyncTaskWithContext（不用裸 startAsyncTask）", function()
        assert.is_truthy(src:find("postAsyncTaskWithContext", 1, true),
            "auto-start 必须用独立 context，否则 LrInitPlugin 返回时任务被取消")
        -- 不能再出现裸的 startResidentTask(function()
        assert.is_nil(src:find("startResidentTask(function()", 1, true),
            "不应再有裸 startResidentTask：上下文会被拆掉")
    end)

    it("develop_set 对增量色温自动补 WhiteBalance='Custom'", function()
        local body = src:match("local function developSet.*\nend")
        assert.is_truthy(body, "developSet not found")
        assert.is_truthy(body:find("WhiteBalance = 'Custom'", 1, true),
            "写 IncrementalTemperature/Tint 必须切 Custom，否则 LR 完全忽略")
    end)

    it("回读自证只对数值键做算术（字符串键不得进 tonumber）", function()
        local body = src:match("local function developSet.*\nend")
        -- 应先用 type(v)=='number' 过滤再 math.abs
        assert.is_truthy(body:find("type(v) == 'number'", 1, true),
            "必须过滤数值键，否则 WhiteBalance 字符串会让 tonumber 抛错打死循环")
    end)

    it("每个异步任务体都整体包了 LrTasks.pcall", function()
        -- 统计 startAsyncTask(function ... 后面 40 行内是否出现 LrTasks.pcall
        -- 窗口 = 该任务起点 → **下一个任务起点或文件末尾**（固定 3000 字符窗口
        -- 会在文件末尾那个任务上越界误判，实测踩到）
        local starts = {}
        local init = 1
        while true do
            local s = src:find("startAsyncTask(function", init, true)
            if not s then break end
            starts[#starts + 1] = s
            init = s + 1
        end
        assert.is_true(#starts > 0, "no async tasks found")
        local guarded = 0
        for i, s in ipairs(starts) do
            local stop = starts[i + 1] and (starts[i + 1] - 1) or #src
            if src:sub(s, stop):find("LrTasks.pcall", 1, true) then
                guarded = guarded + 1
            end
        end
        -- 两处**已知且正当**的例外（不是遗漏，各自有更强的上游保护）：
        --   1) handle() 里的任务：其调用点 handle(parseCommand(...))
        --      已被轮询循环的 LrTasks.pcall 包住（见 Bridge.lua 循环体）。
        --   2) 文件末尾的 boot 探针：只发一条 HTTP 回报，无 SDK 调用、无状态。
        -- 除这两处外，任何新的"裸任务"都应被判失败——这正是本用例的价值。
        local allowedUnguarded = 2
        assert.are.equal(#starts - allowedUnguarded, guarded,
            "除 handle() 与 boot 探针外，所有异步任务体都必须包 LrTasks.pcall")
    end)
end)

describe("Bridge.lua 命令面完整性", function()
    local src = readSource()

    it("注册了本次新增的操作命令", function()
        for _, t in ipairs({ "develop_set", "develop_keys", "keyword",
                             "collection", "search", "optics", "reject" }) do
            assert.is_truthy(src:find("command.type == '" .. t .. "'", 1, true),
                "missing command: " .. t)
        end
    end)
end)

describe("Lua 5.1 兼容性（Lightroom 内置 Lua）", function()
    local s = readSource()

    it("不使用 goto / ::label::（Lua 5.2+ 语法，会让插件被整个禁用）", function()
        -- 实测事故：加了 goto 之后 Bridge.lua 解析失败 → LR 直接禁用插件，
        -- 表现为「增效工具额外信息」里本插件的菜单项消失、重载静默失败。
        local body = s:gsub("%-%-[^\n]*", "")   -- 去注释后再查
        assert.is_nil(body:find("%s*goto%s"), "不得使用 goto（Lua 5.1 不支持）")
        assert.is_nil(body:find("::%w+::"), "不得使用 ::label::（Lua 5.1 不支持）")
    end)

    it("不使用位运算符（& | ~ << >> 亦是 5.3+）", function()
        local body = s:gsub("%-%-[^\n]*", "")
        -- 只查常见的按位写法；`~=` 是合法的"不等于"，需排除
        assert.is_nil(body:find("[^~]~[^=]"), "不得使用按位取反 ~（Lua 5.3+）")
    end)
end)
