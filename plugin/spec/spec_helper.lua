-- 测试基础设施：为 LR SDK 造 mock，让插件源码可在纯 Lua 下 require 并测试。
-- 思路照搬 lightroom-mcp 的 plugin/spec/spec_helper.lua：
--   用 mock 覆盖全局 `import`，再把 .lrplugin 目录加进 package.path，
--   这样 Bridge.lua 可以在没有 Lightroom 的环境里被加载与调用。
--
-- 注意：Bridge.lua 顶层就会启动轮询任务，所以测试**不 require 整个 Bridge.lua**，
-- 而是把要测的纯函数抽出来单独测（见下），或通过 loadfile + 桩环境加载。
-- 这样既能覆盖校验/映射逻辑，又不需要模拟 LR 的协程运行时。

local M = {}

M.PLUGIN_DIR = "Agent Lightroom Bridge.lrplugin"

local sep = package.config:sub(1, 1)
M.PLUGIN_DIR = M.PLUGIN_DIR:gsub("/", sep)

-- 让 plugin/?.lua 可被 require
local pluginRoot = "plugin" .. sep .. M.PLUGIN_DIR .. sep .. "?.lua"
if not package.path:find(pluginRoot, 1, true) then
    package.path = package.path .. ";" .. pluginRoot
end

-- 安装 mock import：Bridge.lua 里所有 import 'X' 都返回 mock
function M.installImport(modules)
    _G.import = function(name)
        local m = modules[name]
        if m == nil then
            error("No mock installed for import('" .. tostring(name) .. "')", 2)
        end
        return m
    end
end

-- 默认 LR 模块桩：足够加载 Bridge.lua 的顶层而不报错
function M.defaultModules(overrides)
    local rec = { results = {}, calls = {} }
    local function logResult(status, message)
        rec.results[#rec.results + 1] = { status = status, message = message }
    end

    local photosById = {}
    local catalog = {
        withWriteAccessDo = function(_, name, fn) fn() end,
        withReadAccessDo = function(_, fn) fn() end,
        getAllPhotos = function() return {} end,
        getChildCollections = function() return {} end,
        createKeyword = function(_, name) return { getName = function() return name end } end,
        findPhotos = function() return {} end,
    }

    local modules = {
        LrApplication = {
            activeCatalog = function() return catalog end,
            developPresetFolders = function() return {} end,
        },
        LrTasks = {
            startAsyncTask = function(fn) fn() end,      -- 同步执行，便于断言
            pcall = function(fn) return pcall(fn) end,
            sleep = function() end,
        },
        LrHttp = { get = function() return '{"type":"idle"}' end },
        LrDialogs = { message = function() end },
        LrFileUtils = {
            exists = function() return false end,
            createAllDirectories = function() end,
            writeFile = nil,
        },
        LrPathUtils = { child = function(a, b) return a .. "/" .. b end },
        LrFunctionContext = {
            postAsyncTaskWithContext = function(_, fn) fn() end,  -- 同步执行
        },
        LrPrefs = { prefsForPlugin = function() return {} end },
    }
    for k, v in pairs(overrides or {}) do modules[k] = v end
    M._rec = rec
    M._catalog = catalog
    return modules
end

-- 极简断言辅助（不依赖 busted 的断言，便于单文件跑）
function M.assertEq(actual, expected, label)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s",
            label or "assertEq", tostring(expected), tostring(actual)), 2)
    end
end

function M.assertContains(haystack, needle, label)
    if type(haystack) ~= "string" or not haystack:find(needle, 1, true) then
        error(string.format("%s: expected %q to contain %q",
            label or "assertContains", tostring(haystack), tostring(needle)), 2)
    end
end

return M
