local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrHttp = import 'LrHttp'
local LrTasks = import 'LrTasks'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'

local BASE = 'http://127.0.0.1:8765'

-- 插件代码版本号：**每次修改本文件都要 bump**。
-- 轮询时带给 bridge，bridge 只服务最高版本 → 旧的常驻循环会被饿死，
-- 于是改动无需重启 Lightroom 即可生效（详见 bridge/server.js 的 /next 注释）。
local PLUGIN_VERSION = 4

-- 注意：catalog 必须「延迟获取」。在 LrInitPlugin 的早期阶段
-- LrApplication.activeCatalog() 可能尚未就绪（返回 nil 或抛错），
-- 若在顶层直接取值会让整个脚本中断，轮询循环永远不会启动。
-- 这里改为每次需要时再取，并且全程做 nil 保护。
local function getCatalog()
    -- 注意：activeCatalog 是 yield API，不能用 pcall 包（会抛
    -- "Yielding is not allowed within a C or metamethod call"）。
    -- LR 在 catalog 未就绪时返回 nil，用 nil 判断即可。
    return LrApplication.activeCatalog()
end


-- Lightroom Lua SDK 没有 LrHttp.urlencode，用纯 Lua 实现（覆盖 & = 空格等）。
-- 注意 gsub 的替换函数返回值按字面使用，% 不会被二次解释，可安全返回 "%XX"。
local function urlencode(s)
    s = tostring(s or '')
    s = s:gsub('([^%w])', function(c) return string.format('%%%02X', string.byte(c)) end)
    return s
end

local function report(status, message)
    LrHttp.get(BASE .. '/result?status=' .. urlencode(status) .. '&message=' .. urlencode(message or ''))
end

-- 字节写盘：LrFileUtils.writeFile 与 io.open 双通道。
-- ⚠️ 本机 LR 15.5 实测：**LrFileUtils.writeFile 是 nil**（探针 probe 可复现），
-- 只有 io 库可用。写图/写应答文件都必须走这里，否则静默失败。
local function writeBytes(path, data)
    if type(LrFileUtils.writeFile) == 'function' then
        local ok = LrTasks.pcall(function() LrFileUtils.writeFile(path, data) end)
        if ok and LrFileUtils.exists(path) then return 'LrFileUtils.writeFile' end
    end
    local okIo = LrTasks.pcall(function()
        local fh = io.open(path, 'wb')
        if not fh then error('io.open failed') end
        fh:write(data)
        fh:close()
    end)
    if okIo and LrFileUtils.exists(path) then return 'io.open' end
    return nil
end

local function reportCatalogPhotos()
    local cat = getCatalog()
    if not cat then
        LrHttp.get(BASE .. '/result?status=error&message=' .. urlencode('catalog not ready'))
        return
    end
    local parts = {}
    local okAll, photos = LrTasks.pcall(function() return cat:getAllPhotos() end)
    if not okAll or not photos then
        LrHttp.get(BASE .. '/result?status=error&message=' .. urlencode('getAllPhotos failed'))
        return
    end
    for _, item in ipairs(photos) do
        local name = item:getFormattedMetadata('fileName') or ''
        local pick = item:getRawMetadata('pickStatus') or 0
        local flag = pick == -1 and 'reject' or pick == 1 and 'select' or 'unflagged'
        -- 拍摄信息（工作站状态行显示用）：拍摄者/焦距/时间/光圈/快门/ISO。
        -- 每个字段都单独 urlencode，避免字段内的 ; | 破坏分隔。
        local shooting = {
            item:getFormattedMetadata('artist') or '',
            item:getFormattedMetadata('focalLength') or '',
            item:getFormattedMetadata('dateTimeOriginal') or '',
            item:getFormattedMetadata('aperture') or '',
            item:getFormattedMetadata('shutterSpeed') or '',
            item:getFormattedMetadata('isoSpeedRating') or '',
        }
        local row = urlencode(name) .. '|' .. flag
        for _, field in ipairs(shooting) do
            row = row .. '|' .. urlencode(field)
        end
        table.insert(parts, row)
    end
    LrHttp.get(BASE .. '/result?status=catalog&message=' .. table.concat(parts, ';'))
end

-- ══════════════════════════════════════════════════════════════════════
-- 正式后期固定流程（完全确定，无 AI 决策）
-- ══════════════════════════════════════════════════════════════════════

-- 取源文件夹下的照片（按路径前缀匹配；folder 为空则取目录全部照片）。
-- 注意 getAllPhotos 是 yield API，必须在异步任务里调用。
local function photosUnder(folder)
    local cat = getCatalog()
    if not cat then return nil, 'catalog not ready' end
    local photos = cat:getAllPhotos()
    if not photos then return nil, 'getAllPhotos failed' end
    if not folder or folder == '' then return photos end
    local prefix = folder:gsub('/+$', '') .. '/'
    local out = {}
    for _, p in ipairs(photos) do
        local path = p:getRawMetadata('path') or ''
        if path:sub(1, #prefix) == prefix then table.insert(out, p) end
    end
    return out
end

local function countDeveloped(photos)
    local n = 0
    for _, p in ipairs(photos) do
        local s = p:getDevelopSettings() or {}
        if s.Exposure ~= nil or s.PerspectiveUpright ~= nil or s.WhiteBalance ~= nil then
            n = n + 1
        end
    end
    return n
end

-- 逐个核对 SDK 关键 API 是否存在（只读探测，不写任何照片）。
-- 存在的写 API（applyAutoTone/applyDevelopSettings）无法在不写入的前提下探测，
-- 因此用类型检查报告。
local function probeApis(folder)
    local photos, err = photosUnder(folder)
    if not photos then return report('error', 'probe failed: ' .. tostring(err)) end
    -- 抽"真正的图片"做样本：视频没有 develop 设置，抽到视频会让回读永远是空，
    -- 于是"自动调整是否写入"这类验证形同虚设（实测踩过）。
    local p = nil
    for _, cand in ipairs(photos) do
        local nm = string.lower(cand:getFormattedMetadata('fileName') or '')
        local ext = nm:sub(-4)
        if ext ~= '.mp4' and ext ~= '.mov' and ext ~= '.m4v' and nm:sub(-4) ~= '.avi' then
            p = cand
            break
        end
    end
    p = p or photos[1]
    if not p then return report('error', 'probe: no photos in folder') end
    local out = {}
    table.insert(out, 'photos=' .. tostring(#photos))
    table.insert(out, 'applyAutoTone=' .. type(p.applyAutoTone))
    table.insert(out, 'applyDevelopSettings=' .. type(p.applyDevelopSettings))
    table.insert(out, 'requestJpegThumbnail=' .. type(p.requestJpegThumbnail))
    table.insert(out, 'getDevelopSettings=' .. type(p.getDevelopSettings))
    -- 目录级 API（读图通道要用）：exportJpeg 直接导出 JPEG 落盘；
    -- addPhoto 直接把文件加进目录（给自动化喂素材，不走导入对话框）。
    local c = getCatalog()
    table.insert(out, 'cat.exportJpeg=' .. type(c and c.exportJpeg))
    table.insert(out, 'cat.addPhoto=' .. type(c and c.addPhoto))
    table.insert(out, 'fileUtils.writeFile=' .. type(LrFileUtils.writeFile))
    table.insert(out, 'io=' .. type(io))
    -- /tmp 读写自测：文件通道（agent 读图）完全依赖它。
    -- 只报 type(io) 不够——真正要证的是 io.open 能用、且 /tmp 可写可读。
    local selftest = '/tmp/al-plugin-selftest.txt'
    local writeOk = 'n/a'
    if type(io) == 'table' and type(io.open) == 'function' then
        local okW = LrTasks.pcall(function()
            local fh = io.open(selftest, 'w')
            if not fh then error('io.open(w) returned nil') end
            fh:write('ok')
            fh:close()
        end)
        writeOk = okW and 'yes' or 'no'
    end
    table.insert(out, 'tmpWrite=' .. writeOk)
    local readOk = 'no'
    if type(io) == 'table' and type(io.open) == 'function' then
        local fhRead = io.open(selftest, 'r')
        if fhRead then
            local content = fhRead:read('*l')
            fhRead:close()
            readOk = (content == 'ok') and 'yes' or 'bad'
        end
    end
    table.insert(out, 'tmpRead=' .. readOk)
    local s = p:getDevelopSettings() or {}
    table.insert(out, 'file=' .. tostring(p:getFormattedMetadata('fileName')))
    table.insert(out, 'PerspectiveUpright=' .. tostring(s.PerspectiveUpright))
    table.insert(out, 'Exposure=' .. tostring(s.Exposure))
    -- 设置键清单（判定「自动调整是否真的写入」的关键证据）
    -- 显式报告「自动调整会改的那些键」——这是判定 Cmd+U 是否真的写入的唯一硬证据。
    -- （早期版本只 dump 前 8 个键，噪声键占满，反而看不出曝光有没有变。）
    local toneKeys = { 'Exposure', 'Contrast', 'Highlights2012', 'Highlights',
                       'Shadows2012', 'Shadows', 'Whites2012', 'Blacks2012',
                       'Temperature', 'Tint', 'AutoTone', 'AutoLateralCA' }
    local tone = {}
    for _, k in ipairs(toneKeys) do
        if s[k] ~= nil then table.insert(tone, k .. '=' .. tostring(s[k])) end
    end
    local count = 0
    for _ in pairs(s) do count = count + 1 end
    table.insert(out, 'settingsKeys=' .. tostring(count))
    table.insert(out, 'tone=[' .. table.concat(tone, ',') .. ']')
    return report('ok', table.concat(out, ' '))
end

-- 固定流程第二段：自动变换（Upright = Auto）。
-- ⚠️ 探针实测（2026-09-19）：本机 LR 15.5 SDK 里 **p:applyAutoTone 不存在（nil）**，
-- 所以「Cmd+U 自动调整」不能走 SDK，由工作站用 CUA 发 Cmd+U 在 UI 层完成。
-- 此命令只负责 Upright：UI 上「裁剪 R → 自动」与「变换面板 → 自动」对应同一个
-- develop 设置 PerspectiveUpright = 1（Upright: Auto），故设一次即可。
-- 写后立即回读，诚实报告实际生效张数。
local function runRoutine(folder)
    LrTasks.startAsyncTask(function()
        local cat = getCatalog()
        if not cat then return report('error', 'catalog not ready') end
        local okList, photos = LrTasks.pcall(function() return photosUnder(folder) end)
        if not okList or not photos then return report('error', 'routine: ' .. tostring(photos)) end
        if #photos == 0 then return report('error', 'routine: no photos under ' .. tostring(folder)) end
        local total = #photos
        report('starting', 'routine: applying Upright=Auto to ' .. total .. ' photos')

        local okWork, errWork = LrTasks.pcall(function()
            cat:withWriteAccessDo('Agent Lightroom routine', function()
                for _, p in ipairs(photos) do
                    p:applyDevelopSettings({ PerspectiveUpright = 1 })
                end
            end, { timeout = 600 })
        end)
        if not okWork then
            return report('error', 'routine failed: ' .. tostring(errWork))
        end

        -- 回读验证：PerspectiveUpright == 1 记为成功
        local okVerify, upright, checked = LrTasks.pcall(function()
            local n, seen = 0, 0
            for _, p in ipairs(photos) do
                local s = p:getDevelopSettings() or {}
                seen = seen + 1
                if s.PerspectiveUpright == 1 then n = n + 1 end
            end
            return n, seen
        end)
        if okVerify then
            report('ok', 'routine done: Upright=Auto on ' .. tostring(upright) .. '/' .. tostring(checked))
        else
            report('ok', 'routine wrote ' .. tostring(total) .. ' photos (verify failed)')
        end
    end)
    return report('starting', 'routine: starting for ' .. tostring(folder))
end

-- LR 内渲染缩略图（含当前基础修图效果）→ 直接写共享临时目录。
-- 这是「选片预览必须是 LR 内基础编辑完成后的预览」的实现路径：
-- 不走原文件，而是拿 LR 渲染结果。app 与 LR 同机，落盘比 HTTP 传大包更稳。
-- 目录：/tmp/al-thumbs/<文件名>.jpg
local THUMB_DIR = '/tmp/al-thumbs'

local function fileBaseName(name)
    return name
end

local function sendThumbs(folder)
    LrTasks.startAsyncTask(function()
        local cat = getCatalog()
        if not cat then return report('error', 'catalog not ready') end
        LrTasks.pcall(function() LrFileUtils.createAllDirectories(THUMB_DIR) end)
        local okList, photos = LrTasks.pcall(function() return photosUnder(folder) end)
        if not okList or not photos then return report('error', 'thumbs: ' .. tostring(photos)) end
        local total = #photos
        local sent, failed = 0, 0
        report('starting', 'thumbs: rendering ' .. total .. ' previews')
        for _, p in ipairs(photos) do
            local name = p:getFormattedMetadata('fileName') or ''
            local target = THUMB_DIR .. '/' .. fileBaseName(name) .. '.jpg'
            local bytes = nil
            -- 通道 A：同步形态（本机 LR 15.5 实测返回空，保留兼容）
            local okT, data = LrTasks.pcall(function() return p:requestJpegThumbnail(512, 512) end)
            if okT and type(data) == 'string' and #data > 0 then bytes = data end
            -- 通道 B：异步回调形态 —— 本机真正能拿到字节的就是它
            -- （与 renderForAgent 同机制）。只走通道 A 会导致 169 张全 failed。
            if not bytes and type(p.requestJpegThumbnail) == 'function' then
                local jpeg, done = nil, false
                LrTasks.pcall(function()
                    p:requestJpegThumbnail(function(b, err)
                        if type(b) == 'string' and #b > 0 then jpeg = b end
                        done = true
                    end, { x = 512, y = 512 })
                end)
                local waited = 0
                while not done and waited < 10 do
                    LrTasks.sleep(0.25)
                    waited = waited + 0.25
                end
                bytes = jpeg
            end
            if bytes then
                if writeBytes(target, bytes) then sent = sent + 1 else failed = failed + 1 end
            else
                failed = failed + 1
            end
        end
        report('ok', 'thumbs done: sent=' .. tostring(sent) .. ' failed=' .. tostring(failed)
            .. ' dir=' .. THUMB_DIR)
    end)
    return report('starting', 'thumbs: starting for ' .. tostring(folder))
end


-- ── 单张「读图」通道：agent 理解图片引擎的核心 ──────────────────────────
-- 一句话：把「LR 里现在的样子」渲染成 JPEG 落盘，agent 读那个文件就能看图。
-- 与 thumbs（批量 512px 小图）互补：本通道**单张、可按文件名指定、默认 1600px**。
-- 关键：这绝不是原文件拷贝——两条通道都走 LR 自己的渲染管线，所以渲染结果包含
-- 当前基础修图（曝光/Upright/白平衡等 develop 设定）。这正是
-- 「选片预览必须是 Lr 内基础编辑完成后的预览」的实现路径。
local VIEW_OUT = '/tmp/agent-lightroom-view.jpg'

local function findPhotoByName(cat, name)
    if not name or name == '' then return nil end
    local okAll, photos = LrTasks.pcall(function() return cat:getAllPhotos() end)
    if not okAll or not photos then return nil end
    for _, item in ipairs(photos) do
        if (item:getFormattedMetadata('fileName') or '') == name then return item end
    end
    return nil
end

-- 渲染核心：给定照片名（空/'-' = 当前选中）与长边尺寸，产出 /tmp 下的 JPEG。
-- 返回 (status, message)；status ∈ {'view','error'}。必须在 task 上下文调用
-- （内部有 yield：getAllPhotos、异步回调等待）。
local function renderForAgent(name, size)
    local cat = getCatalog()
    if not cat then return 'error', 'catalog not ready' end
    local photo
    if name and name ~= '' and name ~= '-' then
        photo = findPhotoByName(cat, name)
        if not photo then return 'error', 'photo not found: ' .. name end
    else
        photo = cat:getTargetPhoto()
        if not photo then return 'error', 'no photo selected' end
    end
    local fileName = photo:getFormattedMetadata('fileName') or ''
    local origPath = photo:getRawMetadata('path') or ''
    size = tonumber(size) or 1600
    local tried = {}

        -- 通道①：catalog:exportJpeg —— SDK 直接写文件（本机实测为 nil，留作兼容）
        if type(cat.exportJpeg) == 'function' then
            local ok, err = LrTasks.pcall(function()
                if LrFileUtils.exists(VIEW_OUT) then LrFileUtils.delete(VIEW_OUT) end
                cat:exportJpeg({ photo = photo, filename = VIEW_OUT, quality = 2 })
            end)
            if ok and LrFileUtils.exists(VIEW_OUT) then
                return 'view', fileName .. '|' .. VIEW_OUT .. '|' .. origPath .. '|exportJpeg'
            end
            table.insert(tried, 'exportJpeg=' .. (ok and 'no-file' or tostring(err)))
        else
            table.insert(tried, 'exportJpeg=absent')
        end

        -- 通道②：photo:requestJpegThumbnail —— 先试同步形态，再试异步回调形态。
        if type(photo.requestJpegThumbnail) == 'function' then
            local okSync, data = LrTasks.pcall(function() return photo:requestJpegThumbnail(size, size) end)
            if okSync and type(data) == 'string' and #data > 0 then
                local how = writeBytes(VIEW_OUT, data)
                if how then
                    return 'view', fileName .. '|' .. VIEW_OUT .. '|' .. origPath .. '|thumb-sync/' .. how
                end
                table.insert(tried, 'thumb-sync=write-failed')
            else
                table.insert(tried, 'thumb-sync=' .. (okSync and 'empty' or tostring(data)))
                local jpeg, cbErr, done = nil, nil, false
                local okAsync = LrTasks.pcall(function()
                    photo:requestJpegThumbnail(function(bytes, err)
                        if type(bytes) == 'string' and #bytes > 0 then jpeg = bytes else cbErr = tostring(err) end
                        done = true
                    end, { x = size, y = size })
                end)
                local waited = 0
                while not done and waited < 20 do
                    LrTasks.sleep(0.25)
                    waited = waited + 0.25
                end
                if jpeg then
                    local how = writeBytes(VIEW_OUT, jpeg)
                    if how then
                        return 'view', fileName .. '|' .. VIEW_OUT .. '|' .. origPath .. '|thumb-async/' .. how
                    end
                    table.insert(tried, 'thumb-async=write-failed')
                else
                    table.insert(tried, 'thumb-async=' .. tostring(cbErr or (okAsync and 'timeout' or 'call-failed')))
                end
            end
        else
            table.insert(tried, 'requestJpegThumbnail=absent')
        end

    return 'error', 'view failed: ' .. table.concat(tried, '; ')
end

local function viewPhoto(command)
    LrTasks.startAsyncTask(function()
        -- 单测发现的缺口：本任务是唯一没有整体护栏的渲染路径，
        -- 渲染失败会变成未捕获错误（→ LR 模态弹窗 → 阻塞轮询）。补上。
        local ok, res = LrTasks.pcall(function()
            return renderForAgent(command.name, command.size)
        end)
        if ok then
            report(res)
        else
            report('error', 'view render failed: ' .. tostring(res))
        end
    end)
    return report('starting', 'view: rendering photo')
end

-- ── 文件通道：agent 读图（绕开 /next 队列的「多轮询循环」竞争）──────────────
-- 背景（实测）：LR 里每点一次「Start Bridge」就多起一个轮询循环，旧循环不会退出。
-- 旧代码不认识新命令，却会把 /next 上的命令抢走并草草回掉——实测 view 被抢走后
-- 回成 "No photo selected in Lightroom"（假失败，反复重试才碰运气成功）。
-- 文件通道**不经过 /next**：旧循环根本不知道这个文件存在，自然无视它，
-- 于是新循环能独占处理 agent 的读图请求，读图从此稳定可复现。
-- 协议（纯文本，避免在 Lua 侧解析 JSON）：
--   /tmp/al-view.request  第1行 token（每次请求唯一）/ 第2行 size / 第3行 文件名（空=当前选中）
--   /tmp/al-view.response 第1行 token / 第2行 status / 第3行 message
-- token 比对保证「同一次请求只处理一次」，也避免把上一轮的旧应答当成本次结果。
local VIEW_REQUEST = '/tmp/al-view.request'
local VIEW_RESPONSE = '/tmp/al-view.response'
local lastViewToken = nil

local function handleViewRequest()
    local fh = io.open(VIEW_REQUEST, 'r')
    if not fh then return end
    local token = fh:read('*l')
    local size = fh:read('*l')
    local name = fh:read('*l')
    fh:close()
    if not token or token == '' or token == lastViewToken then return end
    lastViewToken = token
    local status, message = renderForAgent(name, size)
    local out = io.open(VIEW_RESPONSE, 'w')
    if out then
        out:write(token .. '\n' .. tostring(status) .. '\n' .. tostring(message) .. '\n')
        out:close()
    end
end

-- 把照片文件直接加入当前目录（给自动化喂测试素材，不走导入对话框那套 UI）。
-- files 用 ';' 分隔（命令 JSON 由正则解析，逗号不安全）。
local function addPhotos(files)
    LrTasks.startAsyncTask(function()
        local cat = getCatalog()
        if not cat then return report('error', 'catalog not ready') end
        if type(cat.addPhoto) ~= 'function' then
            return report('error', 'add: cat.addPhoto absent in this SDK')
        end
        local added, failed = 0, 0
        for path in tostring(files or ''):gmatch('[^;]+') do
            local ok = LrTasks.pcall(function()
                cat:withWriteAccessDo('Agent Lightroom add', function() cat:addPhoto(path) end, { timeout = 60 })
            end)
            if ok then added = added + 1 else failed = failed + 1 end
        end
        report('ok', 'add done: added=' .. tostring(added) .. ' failed=' .. tostring(failed))
    end)
    return report('starting', 'add: adding photos to catalog')
end

-- ═══════════════════════════════════════════════════════════════════════
-- 操作便利命令层（搬自 lightroom-mcp 的 HandlerDevelop 白名单思路）
--
-- 为什么需要：原有 develop 命令只认 12 个基础键（exposure/contrast/...），
-- HSL、点曲线、降噪、暗角、颗粒、裁切 这些**根本没法写**。
-- 这里新增一个**按 LR 原生键名直写**的通道 `develop_set`，用一个白名单
-- 约束可写范围（照搬参考实现的做法：白名单 = 安全边界 + 文档）。
--
-- 与既有命令的分工（不改风格、不改语义确认方式）：
--   * `develop`     —— 保留原样，给规则层用的"友好参数名"（exposure 等）
--   * `develop_set` —— 新通道，直接给 LR 原生键名（Exposure2012 / HSL / ...）
-- 这样 VLM 复查流程与修图配方**完全不动**，只是多了一组可用的"手"。
-- ═══════════════════════════════════════════════════════════════════════

-- 可写的 LR 原生 develop 键白名单（实测本机支持；超范围一律拒绝并报错）
local ALLOWED_DEVELOP_KEYS = {
    -- 基础影调
    'Exposure2012', 'Contrast2012', 'Highlights2012', 'Shadows2012',
    'Whites2012', 'Blacks2012', 'Texture', 'Clarity2012', 'Dehaze',
    'Vibrance', 'Saturation',
    -- 白平衡
    'WhiteBalance', 'IncrementalTemperature', 'IncrementalTint',
    -- HSL 八通道（色相/饱和/明度）—— 之前完全缺失
    'HueAdjustmentRed', 'HueAdjustmentOrange', 'HueAdjustmentYellow',
    'HueAdjustmentGreen', 'HueAdjustmentAqua', 'HueAdjustmentBlue',
    'HueAdjustmentPurple', 'HueAdjustmentMagenta',
    'SaturationAdjustmentRed', 'SaturationAdjustmentOrange', 'SaturationAdjustmentYellow',
    'SaturationAdjustmentGreen', 'SaturationAdjustmentAqua', 'SaturationAdjustmentBlue',
    'SaturationAdjustmentPurple', 'SaturationAdjustmentMagenta',
    'LuminanceAdjustmentRed', 'LuminanceAdjustmentOrange', 'LuminanceAdjustmentYellow',
    'LuminanceAdjustmentGreen', 'LuminanceAdjustmentAqua', 'LuminanceAdjustmentBlue',
    'LuminanceAdjustmentPurple', 'LuminanceAdjustmentMagenta',
    -- 参数曲线 / 点曲线
    'ParametricShadows', 'ParametricDarks', 'ParametricLights', 'ParametricHighlights',
    'ParametricShadowSplit', 'ParametricMidtoneSplit', 'ParametricHighlightSplit',
    'ToneCurvePV2012', 'ToneCurvePV2012Red', 'ToneCurvePV2012Green', 'ToneCurvePV2012Blue',
    'ToneCurveName2012',
    -- 色彩分级（分离色调的现代形态）
    'ColorGradeGlobalHue', 'ColorGradeGlobalSat', 'ColorGradeGlobalLum',
    'ColorGradeShadowHue', 'ColorGradeShadowSat', 'ColorGradeShadowLum',
    'ColorGradeMidtoneHue', 'ColorGradeMidtoneSat', 'ColorGradeMidtoneLum',
    'ColorGradeHighlightHue', 'ColorGradeHighlightSat', 'ColorGradeHighlightLum',
    'ColorGradeBlending',
    -- 降噪 / 锐化（第 8 条 AI 降噪相关）
    'Sharpness', 'SharpenRadius', 'SharpenDetail', 'SharpenEdgeMasking',
    'LuminanceSmoothing', 'LuminanceNoiseReductionDetail',
    'LuminanceNoiseReductionContrast', 'ColorNoiseReduction',
    'ColorNoiseReductionDetail', 'ColorNoiseReductionSmoothness',
    -- 光学 / 透视 / 裁切
    'LensProfileEnable', 'AutoLateralCA', 'LensManualDistortionAmount',
    'PerspectiveUpright', 'PerspectiveVertical', 'PerspectiveHorizontal',
    'PerspectiveRotate', 'PerspectiveScale', 'PerspectiveAspect',
    'CropTop', 'CropLeft', 'CropBottom', 'CropRight', 'CropAngle',
    -- 效果：暗角 / 颗粒
    'PostCropVignetteAmount', 'PostCropVignetteMidpoint', 'PostCropVignetteFeather',
    'PostCropVignetteRoundness', 'PostCropVignetteStyle',
    'GrainAmount', 'GrainSize', 'GrainFrequency',
    -- 黑白
    'ConvertToGrayscale',
    -- 拉直
    'StraightenAngle',
}
local ALLOWED_DEVELOP_SET = {}
for _, k in ipairs(ALLOWED_DEVELOP_KEYS) do ALLOWED_DEVELOP_SET[k] = true end

local CURVE_KEYS = {
    ToneCurvePV2012 = true, ToneCurvePV2012Red = true,
    ToneCurvePV2012Green = true, ToneCurvePV2012Blue = true,
}

-- 按 LR 原生键名直写（白名单约束）。参数：
--   { type="develop_set", name="x.jpg", settings={ Exposure2012=0.5, ... } }
-- 点曲线用数组传（0..255 的输入/输出对，必须 偶数个、严格递增、首 0 尾 255）。
local function developSet(command)
    LrTasks.startAsyncTask(function()
      local okTask, errTask = LrTasks.pcall(function()
        local cat = getCatalog()
        if not cat then return report('error', 'catalog not ready') end
        local settings = command.settings
        if type(settings) ~= 'table' then
            return report('error', 'develop_set: settings table required')
        end
        -- 白名单 + 类型校验（拒绝非法键，避免静默写入无效果）
        local clean, rejected, n = {}, {}, 0
        for k, v in pairs(settings) do
            if not ALLOWED_DEVELOP_SET[k] then
                rejected[#rejected + 1] = tostring(k)
            elseif CURVE_KEYS[k] then
                if type(v) ~= 'table' or #v < 4 or #v % 2 ~= 0 then
                    rejected[#rejected + 1] = k .. '(曲线格式错)'
                else
                    clean[k] = v; n = n + 1
                end
            else
                local tv = type(v)
                if tv == 'number' or tv == 'string' or tv == 'boolean' then
                    clean[k] = v; n = n + 1
                else
                    rejected[#rejected + 1] = k .. '(值类型错)'
                end
            end
        end
        if n == 0 then
            return report('error', 'develop_set: no valid setting'
                .. (#rejected > 0 and ('; rejected: ' .. table.concat(rejected, ',')) or ''))
        end
        local photo = findPhotoByName(cat, command.name)
        if not photo then
            return report('error', 'develop_set: photo not found: ' .. tostring(command.name))
        end
        -- 写增量色温/色调时必须切 Custom，否则 LR 会完全忽略（实测坑）
        if clean.IncrementalTemperature or clean.IncrementalTint then
            clean.WhiteBalance = 'Custom'
        end
        local ok, err = LrTasks.pcall(function()
            cat:withWriteAccessDo('Agent Lightroom develop_set', function()
                photo:applyDevelopSettings(clean)
            end)
        end)
        if not ok then return report('error', 'develop_set failed: ' .. tostring(err)) end
        -- 回读自证：只比对**数值键**（字符串键不参与算术，否则抛错打死循环）
        local s = photo:getDevelopSettings() or {}
        local hit, total, miss = 0, 0, {}
        for k, v in pairs(clean) do
            if type(v) == 'number' and k ~= 'StraightenAngle' then
                total = total + 1
                local got = tonumber(s[k])
                if got ~= nil and math.abs(got - v) < 1.01 then
                    hit = hit + 1
                else
                    miss[#miss + 1] = k .. ':' .. tostring(s[k])
                end
            end
        end
        local msg = 'develop_set ' .. hit .. '/' .. total .. ' keys=' .. n
        if #rejected > 0 then msg = msg .. ' rejected=' .. table.concat(rejected, ',') end
        if #miss > 0 then msg = msg .. ' miss=' .. table.concat(miss, ',') end
        if total > 0 and hit == 0 then
            return report('error', 'develop_set NOT persisted: ' .. msg)
        end
        report('ok', msg)
      end)
      if not okTask then
          report('error', 'develop_set task error: ' .. tostring(errTask))
      end
    end)
    return report('starting', 'develop_set: applying')
end

-- 列出白名单（供 agent/前端发现"现在有哪些手可用"）
local function listDevelopKeys()
    report('ok', 'develop keys: ' .. table.concat(ALLOWED_DEVELOP_KEYS, ','))
end

-- ═══════════════════════════════════════════════════════════════════════
-- 组织类命令（关键字 / 收藏夹 / 搜索）—— 搬自 lightroom-mcp 的
-- HandlerOrganization / HandlerCollections / HandlerSearch 的 SDK 用法。
--
-- 定位：纯"操作便利"，**不参与修图决策**（修图配方与 VLM 复查完全不动）。
-- 关键 SDK 事实（照参考实现，勿再猜）：
--   * catalog:createKeyword(name, {}, true, nil, true) —— **同一写事务内不幂等**，
--     必须先去重再建，否则重复创建。
--   * photo:addKeyword(obj) / photo:removeKeyword(obj)
--   * 读关键字：photo:getRawMetadata('keywords')（返回对象数组，取 :getName()）
--   * catalog:getChildCollections() / collectionSet:getChildCollections()
--   * catalog:createCollection(name) / collection:addPhotos(photos)
--   * 搜索：catalog:findPhotos{ searchDesc = {...} }
-- ═══════════════════════════════════════════════════════════════════════

-- 给指定文件名批量加/删关键字。
--   { type="keyword", files={...}, add={"a","b"}, remove={"c"} }
local function editKeywords(command)
    local files = command.files or {}
    if #files == 0 then return report('error', 'keyword: files required') end
    LrTasks.startAsyncTask(function()
      local okTask, errTask = LrTasks.pcall(function()
        local cat = getCatalog()
        if not cat then return report('error', 'catalog not ready') end
        -- 去重（同一事务内 createKeyword 不幂等）
        local addNames, seen = {}, {}
        for _, k in ipairs(command.add or {}) do
            if not seen[k] then seen[k] = true; addNames[#addNames + 1] = k end
        end
        local removeSet = {}
        for _, k in ipairs(command.remove or {}) do removeSet[k] = true end
        if #addNames == 0 and next(removeSet) == nil then
            return report('error', 'keyword: add or remove required')
        end
        local done, missing = 0, {}
        local ok, err = LrTasks.pcall(function()
            cat:withWriteAccessDo('Agent Lightroom keywords', function()
                local kwObjs = {}
                for _, name in ipairs(addNames) do
                    kwObjs[#kwObjs + 1] = cat:createKeyword(name, {}, true, nil, true)
                end
                for _, n in ipairs(files) do
                    local p = findPhotoByName(cat, n)
                    if not p then
                        missing[#missing + 1] = n
                    else
                        for _, obj in ipairs(kwObjs) do p:addKeyword(obj) end
                        if next(removeSet) then
                            local existing = p:getRawMetadata('keywords')
                            if existing then
                                for _, kw in ipairs(existing) do
                                    if removeSet[kw:getName()] then p:removeKeyword(kw) end
                                end
                            end
                        end
                        done = done + 1
                    end
                end
            end)
        end)
        if not ok then return report('error', 'keyword failed: ' .. tostring(err)) end
        local msg = 'keyword done: ' .. done .. '/' .. #files
        if #missing > 0 then msg = msg .. ' missing=' .. table.concat(missing, ',') end
        report('ok', msg)
      end)
      if not okTask then report('error', 'keyword task error: ' .. tostring(errTask)) end
    end)
    return report('starting', 'keyword: applying')
end

-- 列出收藏夹（含收藏夹集层级），或把照片加入指定收藏夹。
--   { type="collection", list=true }
--   { type="collection", name="我的收藏", files={...} }
local function collections(command)
    LrTasks.startAsyncTask(function()
      local okTask, errTask = LrTasks.pcall(function()
        local cat = getCatalog()
        if not cat then return report('error', 'catalog not ready') end
        local found, lines = nil, {}
        -- ⚠️ 实测：不在 withReadAccessDo 里读集合会**拿到空列表**（报 collections(0)），
        -- 而 catalog 里其实有 9 个集合。参考实现把遍历整体放在读事务内，
        -- 这里照做——这是"命令返回 0 但实际有数据"这个假象的根因。
        -- 照参考实现：遍历必须在 withReadAccessDo 内，且**不要**再套 pcall
        -- （withReadAccessDo 是 yield API；给它套 pcall 会抛
        --  "Yielding is not allowed within a C or metamethod call"）。
        cat:withReadAccessDo(function()
            local function walk(colls, depth)
                for _, c in ipairs(colls) do
                    local nm = c:getName()
                    lines[#lines + 1] = string.rep('  ', depth) .. nm
                    if command.name and nm == command.name and not found then
                        found = c
                    end
                    local kids = c:getChildCollections()
                    if kids and #kids > 0 then walk(kids, depth + 1) end
                end
            end
            walk(cat:getChildCollections(), 0)
        end)

        if command.list or not command.name then
            return report('ok', 'collections(' .. #lines .. '): ' .. table.concat(lines, ' | '))
        end
        if not found then
            return report('error', 'collection not found: ' .. tostring(command.name))
        end
        local files = command.files or {}
        if #files == 0 then
            return report('ok', 'collection found: ' .. command.name)
        end
        local targets, missing = {}, {}
        for _, n in ipairs(files) do
            local p = findPhotoByName(cat, n)
            if p then targets[#targets + 1] = p else missing[#missing + 1] = n end
        end
        local ok, err = LrTasks.pcall(function()
            cat:withWriteAccessDo('Agent Lightroom collection add', function()
                found:addPhotos(targets)
            end)
        end)
        if not ok then return report('error', 'collection add failed: ' .. tostring(err)) end
        local msg = 'collection add: ' .. #targets .. '/' .. #files
        if #missing > 0 then msg = msg .. ' missing=' .. table.concat(missing, ',') end
        report('ok', msg)
      end)
      if not okTask then report('error', 'collection task error: ' .. tostring(errTask)) end
    end)
    return report('starting', 'collection: querying')
end

-- 按条件搜索照片，回报文件名列表（供 agent 定位，不依赖 UI 选中态）。
--   { type="search", rating=3, flag="pick", keyword="活动", limit=50 }
local function searchPhotos(command)
    LrTasks.startAsyncTask(function()
      local okTask, errTask = LrTasks.pcall(function()
        local cat = getCatalog()
        if not cat then return report('error', 'catalog not ready') end
        -- 照参考实现（HandlerSearch.buildSearchDesc）的**精确契约**：
        --   desc[1] = { combine = "intersect" }        ← 必须有
        --   { criteria="filename", operation="any",  value=... }
        --   { criteria="rating",   operation="==",   value=... }
        --   { criteria="keywords", operation="all",  value=... }  ← 复数、且逐条插入
        -- 之前我写成 criteria="flag"/"keyword"（单数）→ LR 不认，命令无回报。
        local desc = { combine = 'intersect' }
        if command.rating then
            desc[#desc + 1] = { criteria = 'rating', operation = '==',
                                value = tonumber(command.rating) }
        end
        local kws = command.keywords or (command.keyword and { command.keyword }) or nil
        if kws then
            for _, kw in ipairs(kws) do
                desc[#desc + 1] = { criteria = 'keywords', operation = 'all', value = kw }
            end
        end
        if command.filename then
            desc[#desc + 1] = { criteria = 'filename', operation = 'any',
                                value = command.filename }
        end
        local flagFilter = nil
        if command.flag then
            local v = command.flag
            if v == 'pick' then v = 'pick' elseif v == 'reject' then v = 'reject' end
            -- flag 不是标准 criteria；LR 侧没有稳定的搜索项，故改在**结果上过滤**
            flagFilter = v
        end
        -- ⚠️ 实测事故：把 findPhotos 包进 LrTasks.pcall 会让它**永不返回**
        -- （回报永远停在 "search: running"，该命令把循环堵住）。
        -- 参考实现明确说明：findPhotos 是**异步且会 yield** 的目录查询，
        -- 必须在读事务之外、且**不要**再套 pcall 直接调用。
        -- 无筛选时退回 getAllPhotos（非 yield 枚举），语义也更正确
        -- （未评级照片 rating 为 nil，用 rating 条件会漏掉它们）。
        local hasFilters = #desc > 0
        local photos
        if hasFilters then
            photos = cat:findPhotos({ searchDesc = desc })
        else
            photos = cat:getAllPhotos()
        end
        photos = photos or {}
        local names, limit = {}, tonumber(command.limit) or 100
        for _, p in ipairs(photos or {}) do
            if #names >= limit then break end
            -- ⚠️ 绝不能在这里用 `goto`：Lightroom 15.5 跑的是 **Lua 5.1**，
            -- goto/::label:: 是 5.2+ 语法 → 整份 Bridge.lua 解析失败 →
            -- **插件被 LR 整个禁用**（菜单项消失、重载静默失败）。
            -- 实测踩到：加了 goto 之后「增效工具额外信息」里本插件的项直接不见。
            -- 改用布尔标志做"跳过"。
            local keep = true
            if flagFilter then
                -- pickStatus: 1=pick, -1=reject, 0=unflagged
                local okF, st = pcall(function() return p:getRawMetadata('pickStatus') end)
                if not okF then st = nil end
                if flagFilter == 'pick' and st ~= 1 then keep = false end
                if flagFilter == 'reject' and st ~= -1 then keep = false end
            end
            if keep then
                names[#names + 1] = p:getFormattedMetadata('fileName') or '?'
            end
        end
        report('ok', 'search(' .. #names .. '): ' .. table.concat(names, ','))
      end)
      if not okTask then report('error', 'search task error: ' .. tostring(errTask)) end
    end)
    return report('starting', 'search: running')
end

-- 对**指定文件名的照片**写入 develop 设定（按名字定位，不依赖 UI 选中态）。
-- 用途：①固定流程需要显式落参数；②验证读图通道确实反映 develop 改动。
local function developPhoto(command)
    LrTasks.startAsyncTask(function()
      -- ⚠️⚠️ 这是「[string "Bridge.lua"]:529: attempt to perform arithmetic on a nil
      -- value」反复弹窗的**真根因**，务必理解：
      --   handle() 外层虽然有 LrTasks.pcall，但 startAsyncTask 的函数体是在
      --   handle() **返回之后**才在另一个协程里跑的 —— 外层 pcall 根本罩不住它。
      --   于是异步任务里任何未捕获的算术错误（如自证回读把字符串 "Custom" 拿去
      --   做减法）会变成**未捕获异常弹窗**，并且每来一条命令弹一次，看起来"大量"。
      -- 修法：像 importFolder 那样，把**整个异步任务体**用 LrTasks.pcall 包住，
      --   任何错误都转成 error 回报（可诊断），绝不外泄成模态弹窗。
      local okTask, errTask = LrTasks.pcall(function()
        local cat = getCatalog()
        if not cat then return report('error', 'catalog not ready') end
        local photo = findPhotoByName(cat, command.name)
        if not photo then return report('error', 'develop: photo not found: ' .. tostring(command.name)) end
        -- ⚠️ 实锤坑：LR 15.5（process version 现行）的 develop 键是 **Exposure2012 /
        -- Contrast2012** 等带 2012 后缀的现代键。写旧的 `Exposure` / `Contrast`
        -- 会被 SDK **静默忽略**——applyDevelopSettings 不报错、getDevelopSettings
        -- 读 s.Exposure 仍是 0，于是回报 "ok" 却什么都没改（**假成功**，本项目实际踩过）。
        -- 现代键 + 白平衡增量键全表映射；未给出的键不写，避免覆盖既有编辑。
        local KEYMAP = {
            exposure    = 'Exposure2012',
            contrast    = 'Contrast2012',
            highlights  = 'Highlights2012',
            shadows     = 'Shadows2012',
            whites      = 'Whites2012',
            blacks      = 'Blacks2012',
            clarity     = 'Clarity2012',
            texture     = 'Texture',
            dehaze      = 'Dehaze',
            vibrance    = 'Vibrance',
            saturation  = 'Saturation',
            temperature = 'IncrementalTemperature',  -- 增量色温（勿用 Temperature：那是绝对 K）
            tint        = 'IncrementalTint',
        }
        local settings, applied, bad = {}, {}, {}
        for arg, key in pairs(KEYMAP) do
            local raw = command[arg]
            if raw ~= nil then
                -- ⚠️ tonumber 对非数值输入返回 **nil**。若把 nil 塞进 settings，
                -- 后面自证回读的 math.abs(got_n - want_n) 就会抛
                -- "attempt to perform arithmetic on a nil value" 并**打死轮询循环**。
                -- 这里直接拒绝非法值，不让 nil 进入 settings。
                local n = tonumber(raw)
                if n == nil then
                    bad[#bad + 1] = tostring(arg) .. '=' .. tostring(raw)
                else
                    settings[key] = n
                    applied[#applied + 1] = key
                end
            end
        end
        if #bad > 0 then
            return report('error', 'develop: non-numeric value(s): ' .. table.concat(bad, ' '))
        end
        -- ⚠️ 实锤坑（本机 LR 15.5）：当 develop 里 `WhiteBalance = "As Shot"` 时，
        -- LR **完全忽略** IncrementalTemperature / IncrementalTint —— 写了也读回 0
        -- （getDevelopSettings 内存里能读到新值，但根本不落库）。必须先把
        -- WhiteBalance 切到 "Custom"，增量键才生效。这是「报值正确、catalog 全是 0」
        -- 的真因，不是 SDK 或写权限问题。
        if settings.IncrementalTemperature or settings.IncrementalTint then
            settings.WhiteBalance = 'Custom'
            applied[#applied + 1] = 'WhiteBalance'
        end
        -- 自动拉直（地平线倾角）走独立键，单位=度。
        -- 另注：StraightenAngle 在部分机型/裁剪未启用时 getDevelopSettings 读回 nil，
        -- 因此它**不参与** N/M 自证计数（见下方 readback），只如实回报。
        if command.straighten ~= nil then
            settings.StraightenAngle = tonumber(command.straighten)
            applied[#applied + 1] = 'StraightenAngle'
        end
        -- Upright=Auto（al-tune 判定地平线倾斜时的规范化处理）。
        if command.upright then
            settings.PerspectiveUpright = 1
            applied[#applied + 1] = 'PerspectiveUpright'
        end
        if #applied == 0 then return report('error', 'develop: no known setting in command') end
        local ok, err = LrTasks.pcall(function()
            cat:withWriteAccessDo('Agent Lightroom develop', function()
                photo:applyDevelopSettings(settings)
            end)
        end)
        if not ok then return report('error', 'develop failed: ' .. tostring(err)) end
        -- 回读**现代键**做自证：只有值真的落进 settings 才报 ok。
        -- （读旧键会永远得 0，正是之前「报 ok 实际没写」的根源。）
        -- StraightenAngle 在未启用裁剪时读回 nil 属正常，不计入分母，避免假失败。
        local s = photo:getDevelopSettings() or {}
        local parts, verified, counted = {}, 0, 0
        for _, key in ipairs(applied) do
            local got = s[key]
            parts[#parts + 1] = key .. '=' .. tostring(got)
            -- 只对**数值键**做自证：
            --  * StraightenAngle 未启用裁剪时读回 nil 属正常 → 不计入分母；
            --  * WhiteBalance 是字符串（"Custom"）→ tonumber 得 nil，参与算术会抛
            --    "attempt to perform arithmetic on a nil value" 并**打死轮询循环**
            --    （实锤踩过）。字符串键只做相等比较，绝不能进 tonumber。
            local want = settings[key]
            local want_n, got_n = tonumber(want), tonumber(got)
            if key ~= 'StraightenAngle' and want_n ~= nil then
                counted = counted + 1
                if got_n ~= nil and math.abs(got_n - want_n) < 0.51 then
                    verified = verified + 1
                end
            end
        end
        if counted > 0 and verified == 0 then
            return report('error', 'develop NOT persisted (readback all mismatch): ' .. table.concat(parts, ' '))
        end
        report('ok', 'develop done ' .. verified .. '/' .. counted .. ': ' .. table.concat(parts, ' '))
      end)  -- LrTasks.pcall 结束
      if not okTask then
          -- 把异步任务里的任何意外错误收敛成可诊断的 error 回报，
          -- 而不是让它变成 LR 的模态弹窗（弹窗会阻塞轮询、且每命令弹一次）。
          report('error', 'develop task error: ' .. tostring(errTask))
      end
    end)
    return report('starting', 'develop: applying settings')
end

-- 光学与几何矫正（工序①②：物理正确性，与审美无关，应无条件先做）。
-- 为什么单独做一个命令而不是塞进 develop：这两步是**开关式**动作，
-- 实测用户对 96%/93% 的照片都开了（LensProfileEnable / PerspectiveUpright），
-- 属于"每张都做"的默认工序；而 develop 是逐张不同的影调参数。
local function correctOptics(command)
    LrTasks.startAsyncTask(function()
      local okTask, errTask = LrTasks.pcall(function()
        local cat = getCatalog()
        if not cat then return report('error', 'catalog not ready') end
        local photo = findPhotoByName(cat, command.name)
        if not photo then
            return report('error', 'optics: photo not found: ' .. tostring(command.name))
        end
        local settings = {
            LensProfileEnable = 1,        -- 镜头配置文件矫正（畸变/暗角）
            AutoLateralCA = 1,            -- 自动去横向色差
            PerspectiveUpright = 1,       -- Upright=Auto（自动水平/透视）
        }
        -- 允许显式关闭某一项（例如鱼眼或故意保留畸变时）
        if command.lens == false then settings.LensProfileEnable = 0 end
        if command.upright == false then settings.PerspectiveUpright = 0 end
        local ok, err = LrTasks.pcall(function()
            cat:withWriteAccessDo('Agent Lightroom optics', function()
                photo:applyDevelopSettings(settings)
            end)
        end)
        if not ok then return report('error', 'optics failed: ' .. tostring(err)) end
        -- 自证回读：只认 catalog 里真的落了值（数值键，字符串键不参与算术）
        local s = photo:getDevelopSettings() or {}
        local got = {}
        for _, k in ipairs({ 'LensProfileEnable', 'AutoLateralCA', 'PerspectiveUpright' }) do
            got[#got + 1] = k .. '=' .. tostring(s[k])
        end
        report('ok', 'optics done: ' .. table.concat(got, ' '))
      end)
      if not okTask then
          report('error', 'optics task error: ' .. tostring(errTask))
      end
    end)
    return report('starting', 'optics: applying lens+upright')
end

-- 只写「排除」选片标记（工序④的一部分：把 VLM+数值双方一致的废片落库）。
-- 为什么与 decision 分开：decision 需要 UI 选中态，而本命令按**文件名**定位，
-- 适合批处理里对已判定的废片逐张落标记，且默认只写 reject、不碰 keep/rating。
local function rejectPhotos(command)
    local names = command.files or {}
    if #names == 0 then return report('error', 'reject: no files given') end
    LrTasks.startAsyncTask(function()
      local okTask, errTask = LrTasks.pcall(function()
        local cat = getCatalog()
        if not cat then return report('error', 'catalog not ready') end
        local done, missing = 0, {}
        cat:withWriteAccessDo('Agent Lightroom reject', function()
            for _, n in ipairs(names) do
                local p = findPhotoByName(cat, n)
                if p then
                    p:setRawMetadata('pickStatus', -1)
                    done = done + 1
                else
                    missing[#missing + 1] = n
                end
            end
        end)
        local msg = 'reject done: ' .. done .. '/' .. #names
        if #missing > 0 then msg = msg .. ' missing=' .. table.concat(missing, ',') end
        report('ok', msg)
      end)
      if not okTask then
          report('error', 'reject task error: ' .. tostring(errTask))
      end
    end)
    return report('starting', 'reject: marking ' .. #names .. ' photos')
end

local function importFolder(folder)
    if not LrFileUtils.exists(folder) then return report('error', 'source folder not found') end
    LrTasks.startAsyncTask(function()
        local cat = getCatalog()
        if not cat then return report('error', 'catalog not ready') end
        -- triggerImportUI 是 yield API：不能用普通 pcall（会抛
        -- "Yielding is not allowed..."），但可以用 LrTasks.pcall —— 它是 LR 为
        -- yield 环境提供的 pcall。没有它的话，一旦 triggerImportUI 抛错，
        -- 异步任务里无人捕获，回报会永远停在 "starting"（曾实际发生）。
        local ok, err = LrTasks.pcall(function() cat:triggerImportUI(folder) end)
        if ok then
            report('ok', 'Lightroom Import window opened')
        else
            report('error', 'triggerImportUI failed: ' .. tostring(err))
        end
    end)
    return report('starting', 'Opening Lightroom Import for ' .. folder)
end

local function handle(command)
    if command.type == 'ping' then
        return report('ok', 'Lightroom Classic connected')
    end
    if command.type == 'snapshot' then return reportCatalogPhotos() end
    -- 正式后期固定流程（无需选中照片，按源文件夹批量执行）
    if command.type == 'probe' then return probeApis(command.source) end
    if command.type == 'routine' then return runRoutine(command.source) end
    if command.type == 'optics' then return correctOptics(command) end
    if command.type == 'reject' then return rejectPhotos(command) end
    if command.type == 'thumbs' then return sendThumbs(command.source) end
    -- 单张读图（agent 看图）与测试素材注入
    if command.type == 'view' then return viewPhoto(command) end
    if command.type == 'add' then return addPhotos(command.files) end
    if command.type == 'develop' then return developPhoto(command) end
    if command.type == 'develop_set' then return developSet(command) end
    if command.type == 'develop_keys' then return listDevelopKeys() end
    if command.type == 'keyword' then return editKeywords(command) end
    if command.type == 'collection' then return collections(command) end
    if command.type == 'search' then return searchPhotos(command) end
    if command.type == 'import' then
        if command.source and command.source ~= '' then return importFolder(command.source) end
        local paths = LrDialogs.runOpenPanel({
            title = '选择要导入的照片文件夹',
            canChooseFiles = false,
            canChooseDirectories = true,
            allowsMultipleSelection = false,
        })
        if not paths or not paths[1] then return report('cancelled', 'Import cancelled') end
        return importFolder(paths[1])
    end
    local cat = getCatalog()
    if not cat then return report('error', 'catalog not ready') end
    local photo = cat:getTargetPhoto()
    if not photo then return report('error', 'No photo selected in Lightroom') end
    if command.type == 'decision' then
        local pick = 0
        if command.value == 'keep' or command.value == 'master' then pick = 1 end
        if command.value == 'reject' then pick = -1 end
        local value = command.value
        -- withWriteAccessDo 是 yield API，必须放到异步任务里，绝不能在外层 pcall 内调用。
        LrTasks.startAsyncTask(function()
            -- withWriteAccessDo 是 yield API：在异步任务里直接调用，不要 pcall。
            cat:withWriteAccessDo('Agent Lightroom decision', function()
                photo:setRawMetadata('pickStatus', pick)
                if value == 'master' then photo:setRawMetadata('rating', 5) end
            end)
            report('ok', 'selection updated')
        end)
        return report('starting', 'applying selection')
    end
    if command.type == 'adjust' then
        -- ⚠️ 这里原来写的是旧键 exposure/contrast/temperature/tint，且 tonumber 结果
        -- 可能为 nil 直接参与 `/ 20` → 抛 arithmetic on nil value 打死轮询循环。
        -- 现在统一：① 用现代键；② 先校验数值再运算；③ 与 develop 走同一套映射。
        local settings, badAdj = {}, {}
        local function put(num_arg, key, scale)
            local raw = command[num_arg]
            if raw == nil then return end
            local n = tonumber(raw)
            if n == nil then
                -- 不能在这里直接 report 后 return：调用方不会检查返回值，
                -- 错误会被静默吞掉，然后拿半截 settings 去写（曾这样写过）。
                -- 统一收集非法值，写之前一次性拒绝。
                badAdj[#badAdj + 1] = tostring(num_arg) .. '=' .. tostring(raw)
                return
            end
            settings[key] = scale and (n / scale) or n
        end
        put('exposure', 'Exposure2012', 20)      -- 与旧契约一致：/20
        put('contrast', 'Contrast2012', 20)
        put('temperature', 'IncrementalTemperature')
        put('tint', 'IncrementalTint')
        if #badAdj > 0 then
            return report('error', 'adjust: non-numeric value(s): ' .. table.concat(badAdj, ' '))
        end
        if settings.IncrementalTemperature or settings.IncrementalTint then
            settings.WhiteBalance = 'Custom'
        end
        if next(settings) == nil then
            return report('error', 'adjust: no known setting in command')
        end
        LrTasks.startAsyncTask(function()
            local okAdj, errAdj = LrTasks.pcall(function()
                cat:withWriteAccessDo('Agent Lightroom adjustment', function()
                    photo:applyDevelopSettings(settings)
                end)
            end)
            if not okAdj then
                return report('error', 'adjust failed: ' .. tostring(errAdj))
            end
            report('ok', 'develop settings applied')
        end)
        return report('starting', 'applying develop settings')
    end
    if command.type == 'sync' then
        -- 2026-09-19 实锤：本机 LR 15.5 SDK 里 cat:getMultipleSelectedPhotos 是 nil，
        -- 直接调用会抛 "attempt to call method ... (a nil value)" 并**杀死整个轮询循环**。
        -- 官方可用的等价 API 是 getSelectedPhotos()，两者都做存在性回退。
        local selected = nil
        if type(cat.getMultipleSelectedPhotos) == 'function' then
            selected = cat:getMultipleSelectedPhotos()
        elseif type(cat.getSelectedPhotos) == 'function' then
            selected = cat:getSelectedPhotos()
        end
        local targets = selected and #selected > 0 and selected or { photo }
        local source = photo:getDevelopSettings()
        LrTasks.startAsyncTask(function()
            local okSync, errSync = LrTasks.pcall(function()
                cat:withWriteAccessDo('Agent Lightroom sync develop settings', function()
                    for _, target in ipairs(targets) do
                        if target ~= photo then target:applyDevelopSettings(source) end
                    end
                end)
            end)
            if okSync then
                report('ok', 'synced ' .. tostring(#targets) .. ' photos')
            else
                report('error', 'sync failed: ' .. tostring(errSync))
            end
        end)
        return report('starting', 'syncing develop settings')
    end
    return report('ok', 'command received')
end

-- Lightroom Lua SDK 没有 LrJson 命名空间，用官方兼容的正则解析命令。
-- 简数字段（type/value/source/exposure/contrast/temperature/tint/count/path）都安全。
-- ⚠️ 2026-09-22：原实现是**扁平正则解析**（`"key":"value"` 逐对抓），
-- 无法处理**嵌套对象/数组**——而新增的 develop_set（settings={...}）、
-- keyword（add={...}）、reject（files={...}）全部依赖嵌套结构。
-- 实测症状：命令能到 handler，但 `settings` 整个丢失，报 "settings table required"。
--
-- 这里改为**真正的递归 JSON 解析器**（纯 Lua，无依赖，够用即可）：
-- 支持 object / array / string / number / true,false,null，并处理转义。
-- 仍保留一个"扁平兜底"路径：若 JSON 解析失败（旧客户端可能发非严格 JSON），
-- 退回原来的正则逻辑，保证向后兼容、不打断既有命令。
local function parseJSON(str)
    local pos = 1
    local function skip()
        while pos <= #str do
            local c = str:sub(pos, pos)
            if c == ' ' or c == '\t' or c == '\n' or c == '\r' then pos = pos + 1 else break end
        end
    end
    local parseValue
    local function parseString()
        pos = pos + 1                       -- 跳过开引号
        local out, esc = {}, false
        while pos <= #str do
            local c = str:sub(pos, pos)
            if esc then
                local map = { n = '\n', t = '\t', r = '\r', ['"'] = '"',
                              ['\\'] = '\\', ['/'] = '/' }
                out[#out + 1] = map[c] or c
                esc = false
            elseif c == '\\' then
                esc = true
            elseif c == '"' then
                pos = pos + 1
                return table.concat(out)
            else
                out[#out + 1] = c
            end
            pos = pos + 1
        end
        error('unterminated string')
    end
    local function parseNumber()
        local s = pos
        while pos <= #str and str:sub(pos, pos):match('[%d%.%+%-eE]') do pos = pos + 1 end
        return tonumber(str:sub(s, pos - 1))
    end
    parseValue = function()
        skip()
        local c = str:sub(pos, pos)
        if c == '{' then
            pos = pos + 1
            local obj = {}
            skip()
            if str:sub(pos, pos) == '}' then pos = pos + 1; return obj end
            while true do
                skip()
                local k = parseString()
                skip()
                if str:sub(pos, pos) ~= ':' then error('expected :') end
                pos = pos + 1
                obj[k] = parseValue()
                skip()
                local d = str:sub(pos, pos)
                if d == ',' then pos = pos + 1
                elseif d == '}' then pos = pos + 1; break
                else error('expected , or }') end
            end
            return obj
        elseif c == '[' then
            pos = pos + 1
            local arr = {}
            skip()
            if str:sub(pos, pos) == ']' then pos = pos + 1; return arr end
            while true do
                arr[#arr + 1] = parseValue()
                skip()
                local d = str:sub(pos, pos)
                if d == ',' then pos = pos + 1
                elseif d == ']' then pos = pos + 1; break
                else error('expected , or ]') end
            end
            return arr
        elseif c == '"' then
            return parseString()
        elseif str:sub(pos, pos + 3) == 'true' then pos = pos + 4; return true
        elseif str:sub(pos, pos + 4) == 'false' then pos = pos + 5; return false
        elseif str:sub(pos, pos + 3) == 'null' then pos = pos + 4; return nil
        else
            return parseNumber()
        end
    end
    local ok, value = pcall(parseValue)
    if not ok then return nil end
    return value
end

local function parseCommand(response)
    -- 首选：真正的 JSON 解析（支持嵌套）
    local parsed = parseJSON(response)
    if type(parsed) == 'table' and parsed.type ~= nil then
        return parsed
    end
    -- 兜底：旧的扁平正则解析（保证向后兼容，绝不让既有命令失效）
    local command = {}
    for key, value in response:gmatch('"([%w_]+)"%s*:%s*"?([^,"}]+)') do
        command[key] = value:gsub('"', '')
    end
    return command
end

-- 2026-09-19 实锤：本机 LR Classic 15.5 的 SDK 里没有 LrTasks.addIdleTask
-- （字段为 nil，调用即抛 "attempt to call field 'addIdleTask' (a nil value)"
-- 并当场杀死整个插件脚本，轮询永远不会启动——这才是「导入窗口不出现」的根因）。
--
-- ⚠️⚠️ 2026-09-22 关键修法（搬自 lightroom-mcp 的 PluginInit.lua，纯收益）：
-- 轮询任务**必须用 LrFunctionContext.postAsyncTaskWithContext 起**，
-- 不能用裸 LrTasks.startAsyncTask。
--   裸 startAsyncTask 跑在**本初始化脚本的函数上下文**里；LrInitPlugin 一返回，
--   该上下文即被销毁，任务会在 sleep 途中被 **cancel 掉**。
--   表现正是我们反复遇到的：点 Start Bridge 后 resultSeq 前进一下、
--   随后循环静默死亡（lastSeen 变旧、queue 堆积）——不是代码错，是上下文被拆了。
--   新 context 独立于初始化脚本，能活过返回。
-- 另外按参考实现加了两点鲁棒性：
--   ① sleep(0.5) 让「Reload Plug-in」时上一实例的 context 先 flush（避免端口/竞争）；
--   ② 用 LrTasks.pcall 包住并在失败时回报，避免"auto-start 静默死亡"。
local LrFunctionContext = import 'LrFunctionContext'

local function pollLoop()
    while true do
        -- 重要（踩过坑）：本循环内**一律不使用 pcall**。LR 的 LrHttp.get /
        -- withWriteAccessDo / triggerImportUI / activeCatalog 等全部是 yield API，
        -- 只要被 pcall 包住就会抛
        --   "Yielding is not allowed within a C or metamethod call"
        -- 并让整个 while 循环退出（插件从此静默、队列无限积压）。
        -- 这些 API 失败时返回 nil 或由所在的异步任务承载错误，循环本身足够健壮。
        -- LrHttp.get 本身也是 yield API（实测：包进 pcall 会抛
        -- "Yielding is not allowed within a C or metamethod call"），
        -- 因此这里**不做 pcall**：LR 的 HTTP 失败时返回 nil 而不是抛错，
        -- 用 nil 判断即可，循环不会因此中断。
        local response = LrHttp.get(BASE .. '/next')

        -- 「无命令」时 bridge 返回 {"type":"idle"}，它也含 "type":" 字样；
        -- 不过滤就会被当成命令，走到 handle 末尾回 "command received"，
        -- 覆盖掉真实结果（曾导致 lastResult 永远停在 command received）。
        if response and response:find('"type":"') and not response:find('"type":"idle"') then
            -- 护栏：用 LrTasks.pcall（LR 为 yield 环境提供的 pcall）包住**单条命令的处理**。
            -- 教训：普通 Lua pcall 包 yield API 会抛 "Yielding is not allowed..."，
            -- 但 LrTasks.pcall 是为此设计的。此前没有这层护栏时，任何一条命令里的
            -- SDK 缺失方法（如 getMultipleSelectedPhotos= nil）都会抛出未捕获错误，
            -- 直接把整个 while 循环打死 → 插件静默、队列无限积压（反复复现）。
            -- 注意：循环自身的 LrHttp.get / LrTasks.sleep 仍未包 pcall（保持原规则）。
            local okHandle, errHandle = LrTasks.pcall(function()
                handle(parseCommand(response))
            end)
            if not okHandle then
                -- 单条命令失败只报告，不让循环退出。
                LrHttp.get(BASE .. '/result?status=error&message='
                    .. urlencode('handler error: ' .. tostring(errHandle)))
            end
        end
        -- 文件通道：agent 读图请求（/tmp/al-view.request）。
        -- 与 /next 并行存在，互不影响；旧轮询循环不认识该文件，因此不会被抢走。
        -- 用 LrTasks.pcall 护栏：单次读图失败不能杀死轮询循环。
        local okViewReq, errViewReq = LrTasks.pcall(handleViewRequest)
        if not okViewReq then
            LrHttp.get(BASE .. '/result?status=error&message='
                .. urlencode('view request error: ' .. tostring(errViewReq)))
        end
        LrTasks.sleep(1)
    end
end

-- 用独立 context 起轮询（见上方长注释：裸 startAsyncTask 会被初始化上下文拆掉）。
-- 这是 auto-start 生效的关键；失败时必须回报，不能静默死亡。
LrFunctionContext.postAsyncTaskWithContext("AgentLightroomBridgePoll", function()
    -- 让上一实例（Reload Plug-in 时）的 context 先 flush，避免端口/状态竞争
    LrTasks.sleep(0.5)
    local ok, err = LrTasks.pcall(pollLoop)
    if not ok then
        -- 兜底：轮询体本身抛错也要留下痕迹（否则又是"静默死亡"）
        LrTasks.pcall(function()
            LrHttp.get(BASE .. '/result?status=error&message='
                .. urlencode('poll loop died: ' .. tostring(err)))
        end)
    end
end)

-- 启动提示改为「无模态」的 HTTP 探针：LrDialogs.message 会在 LR 启动阶段弹出
-- 模态框，阻塞插件初始化与轮询启动，对无人值守是有害的（自动化必须无弹窗）。
-- LrHttp 是 yield API，不能包 pcall；直接调用即可。
-- 插件自身文件 IO 能力自检，随 boot 回报一起送出。
-- 理由：读图通道要么靠插件写文件（io.open），要么改成把字节回传 bridge 落盘；
-- 这件事必须用「不依赖插件文件 IO」的通道问清楚——HTTP 回报正是这样的通道。
-- 判据：点一次 Start Bridge 后 /health 的 resultSeq 前进且 lastResult.status=boot，
-- 即说明新循环确实起来了（否则是菜单点击没生效 / 新脚本载入即失败）。
local function pluginSelfTest()
    local parts = { 'io=' .. type(io) }
    if type(io) == 'table' then parts[#parts + 1] = 'io.open=' .. type(io.open) end
    parts[#parts + 1] = 'writeFile=' .. type(LrFileUtils.writeFile)
    parts[#parts + 1] = 'createDirs=' .. type(LrFileUtils.createAllDirectories)
    local probe = '/tmp/al-plugin-selftest.txt'
    if type(io) == 'table' and type(io.open) == 'function' then
        local ok = LrTasks.pcall(function()
            local fh = io.open(probe, 'w')
            if not fh then error('io.open(w) returned nil') end
            fh:write('ok')
            fh:close()
        end)
        parts[#parts + 1] = 'tmpWrite=' .. (ok and 'yes' or 'no')
        local fhRead = io.open(probe, 'r')
        if fhRead then
            local content = fhRead:read('*l')
            fhRead:close()
            parts[#parts + 1] = 'tmpRead=' .. ((content == 'ok') and 'yes' or 'bad')
        else
            parts[#parts + 1] = 'tmpRead=no'
        end
    else
        parts[#parts + 1] = 'tmpWrite=n/a'
    end
    return table.concat(parts, ' ')
end

-- ⚠️ 2026-09-19 实锤（真凶）：下面这条 HTTP 探针**必须放进 task**。
-- 顶层直接调 LrHttp.get 时，若 LR 在**非 task 上下文**加载本脚本（启动扫描插件时
-- 会这样），会抛 "We can only wait from within a task"（LR 日志可复现：
-- lrc_console.log 里 `We can only wait from within a task ... Bridge.lua:<末行>`）。
-- 后果不是"探针没发出"这么轻——**LR 会认为插件加载失败并自动禁用本插件**，
-- 表现为「文件 → 增效工具额外信息」里我们的菜单项整个消失、外部重载静默失败，
-- 且反复复发（每次重启 LR 都可能再来一次）。
LrTasks.startAsyncTask(function()
    LrHttp.get(BASE .. '/result?status=boot&message=' .. urlencode('plugin-loaded ' .. pluginSelfTest()))
end)
