import Foundation

/// 轻量 MCP client：启动 dsh-cua 子进程（stdio JSON-RPC 2.0，行分隔），
/// 用于驱动 Lightroom 等不暴露 System Events 控件的 app 的 UI。
/// 只读接入自家 agent 写的 dsh-cua，不改动它。
/// 内部用一把 NSLock 串行化「发送+读取响应」完整周期（含握手），保证线程安全；
/// 用 @unchecked Sendable 通过 Swift 6 并发检查（状态访问全部经锁保护）。
final class CUAClient: @unchecked Sendable {
    static let shared = CUAClient()

    private let binary = "/Users/tristan/Applications/dsh-cua.app/Contents/MacOS/dsh-cua"
    private var process: Process?
    private var stdin: FileHandle?
    private var stdoutFH: FileHandle?
    private var nextId: Int = 1
    private let lock = NSLock()          // 串行化整个 send+recv 周期，避免并发交错
    private var initialized = false

    private init() {}

    // MARK: - 底层原语（调用方须已持锁）

    private func rawSend(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let handle = stdin else { return }
        let line = String(data: data, encoding: .utf8)! + "\n"
        handle.write(line.data(using: .utf8)!)
    }

    /// 发送请求并阻塞读取匹配 id 的响应行。必须在持锁状态下调用。
    private func rawRequest(method: String, params: [String: Any]) throws -> [String: Any] {
        let id = nextId
        nextId += 1
        let msg: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        ]
        rawSend(msg)

        guard let fh = stdoutFH else { throw CUAError.noProcess }
        var pending = ""          // 尚未凑成完整行的半行
        var lastPartial = ""
        for _ in 0..<400 { // ~20s 上限
            let chunk = fh.availableData
            if chunk.isEmpty {
                Thread.sleep(forTimeInterval: 0.05); continue
            }
            guard let text = String(data: chunk, encoding: .utf8) else { continue }
            pending.append(text)
            // 按行切分；最后一段若不以换行结尾则是半行，留作下次续读
            let lines = pending.components(separatedBy: "\n")
            let complete = lines.dropLast()                 // 去掉最后一个（可能是半行）
            pending = lines.last ?? ""
            for line in complete {
                if line.isEmpty { continue }
                lastPartial = line
                if let obj = try? JSONSerialization.jsonObject(with: line.data(using: .utf8)!) as? [String: Any],
                   let rid = obj["id"] {
                    let match = (rid as? Int == id) || ((rid as? String).flatMap(Int.init) == id)
                    if match { return obj }
                }
            }
        }
        throw CUAError.noResponse(lastPartial)
    }

    // MARK: - 启动 + 握手（持锁，且不再递归调用加锁方法）

    private func ensureStarted() throws {
        if let p = process, p.isRunning, initialized { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = ["mcp"]
        let out = Pipe()
        let err = Pipe()
        let inPipe = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        proc.standardInput = inPipe
        try proc.run()
        process = proc
        stdin = inPipe.fileHandleForWriting
        stdoutFH = out.fileHandleForReading

        // 握手：initialize → notifications/initialized（通知，无 id 不回）
        _ = try rawRequest(method: "initialize", params: [
            "protocolVersion": "2024-11-05",
            "capabilities": [:],
            "clientInfo": ["name": "AgentLightroom", "version": "1.0.0"],
        ])
        rawSend(["jsonrpc": "2.0", "method": "notifications/initialized", "params": [:]])
        initialized = true
    }

    /// 对外统一入口：加锁 → 确保启动 → 发请求 → 读响应 → 解锁。
    private func call(method: String, params: [String: Any]) throws -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        try ensureStarted()
        return try rawRequest(method: method, params: params)
    }

    /// 调用一个 dsh-cua 工具，返回 content[0].text 或抛错。
    func callTool(_ name: String, arguments: [String: Any]) throws -> String {
        let resp = try call(method: "tools/call", params: ["name": name, "arguments": arguments])
        if let result = resp["result"] as? [String: Any] {
            if let isErr = result["isError"] as? Bool, isErr {
                let txt = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? "tool error"
                throw CUAError.toolError(txt)
            }
            let content = result["content"] as? [[String: Any]] ?? []
            return content.first?["text"] as? String ?? ""
        }
        if let err = resp["error"] as? [String: Any] {
            throw CUAError.rpcError(String(describing: err["message"] ?? err))
        }
        throw CUAError.unexpected
    }

    // MARK: - 高层封装：Lightroom 导入

    /// 取 LR 当前窗口 AX 树文本（全量）。
    func lightroomAppState() throws -> String {
        try callTool("get_app_state", arguments: [
            "app": "com.adobe.LightroomClassicCC7",
            "disableDiff": true,
        ])
    }

    /// 在 LR 导入对话框树里定位「导入」按钮（AXButton 且标题精确为"导入"），
    /// 返回 (index, disabled)。disabled=true 表示按钮灰禁用（通常因源里没有新照片可导入）。
    func findLightroomImportButton() throws -> (index: Int, disabled: Bool)? {
        let text = try lightroomAppState()
        // 匹配形如 [61] AXButton "导入" desc=... 的行，排除 [1] AXCheckBox "导入" desc="导入模式"
        let linePattern = #"\[(\d+)\]\s+AXButton\s+"导入""#
        guard let regex = try? NSRegularExpression(pattern: linePattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let rng = Range(match.range(at: 1), in: text),
              let idx = Int(text[rng]) else { return nil }
        // 取该按钮所在行的完整文本，判断是否有 DISABLED
        let range = Range(match.range, in: text)!
        let lineRange = text.lineRange(for: range)
        let lineText = String(text[lineRange])
        let disabled = lineText.contains("DISABLED")
        return (idx, disabled)
    }

    /// 点击 LR 导入对话框里的「导入」按钮：取树→定位→点击（必须在同一快照窗口内完成）。
    /// 返回：nil=未找到按钮；.found(disabled:true)=按钮灰禁用（无新照片）；.clicked=已点击提交。
    enum ImportClickResult { case notFound, disabled, clicked }

    /// 轮询等待 LR 导入对话框出现并点击「导入」。
    /// triggerImportUI 是异步的，LR 打开对话框并扫描源文件夹需要数秒，
    /// 因此这里轮询最多 `timeout` 秒，而不是只读一次。
    func clickLightroomImport(timeout: TimeInterval = 20) throws -> ImportClickResult {
        let deadline = Date().addingTimeInterval(timeout)
        var lastTreeNote = ""
        while Date() < deadline {
            let text = try lightroomAppState()
            guard let found = try parseImportButton(in: text) else {
                // 记录诊断：树是否为空 / 是否含 LR 窗口
                lastTreeNote = text.count < 200 ? "AX 树为空（dsh-cua 可能无辅助功能权限）" : "未见导入对话框"
                Thread.sleep(forTimeInterval: 0.5)
                continue
            }
            if found.disabled {
                // 按钮已出现但灰禁用：源里没有新照片，无需继续等
                return .disabled
            }
            _ = try callTool("click", arguments: [
                "app": "com.adobe.LightroomClassicCC7",
                "element_index": found.index,
            ])
            return .clicked
        }
        lastNotFoundDetail = lastTreeNote
        return .notFound
    }

    /// 上次 notFound 的诊断细节（供上层显示，区分权限问题与窗口未就绪）。
    private(set) var lastNotFoundDetail: String = ""

    // MARK: - 导入预设（规格第 1 条：选择导入预设-社团导入）

    /// 在 LR 导入窗里选择「导入预设」下拉里的指定预设。
    /// 实测要点（2026-09-19）：
    ///  ① 下拉必须用 AXShowMenu action 打开，AXPress/click **打不开**（LR 自绘）；
    ///  ② 菜单项标题带前导空格（实际是 "  社团导入"），必须 trim 后比较；
    ///  ③ element_index 只对最近一次快照有效——每个动作后都要重新取树。
    /// 返回是否成功选中（失败时上层如实报告，不假装已选）。
    @discardableResult
    func selectImportPreset(named preset: String, timeout: TimeInterval = 20) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // ── 取新鲜索引 ──
            let text = try lightroomAppState()
            guard let popupIndex = Self.parseElementIndex(in: text, idEquals: "Popup_ImportPreset") else {
                Thread.sleep(forTimeInterval: 0.6)
                continue
            }
            // ── 已经是目标预设就不动它 ──
            if Self.currentPopupValue(in: text, id: "Popup_ImportPreset")?
                .trimmingCharacters(in: .whitespaces) == preset {
                return true
            }
            // ── ① 用 AXShowMenu 打开下拉 ──
            _ = try callTool("perform_secondary_action", arguments: [
                "app": "com.adobe.LightroomClassicCC7",
                "element_index": popupIndex,
                "action": "AXShowMenu",
            ])
            Thread.sleep(forTimeInterval: 1.2)
            // ── ② 在展开的下拉里按 trim 后的标题找预设项 ──
            let opened = try lightroomAppState()
            if let itemIndex = Self.parseElementIndex(in: opened, trimmedTitle: preset) {
                _ = try callTool("click", arguments: [
                    "app": "com.adobe.LightroomClassicCC7",
                    "element_index": itemIndex,
                ])
                Thread.sleep(forTimeInterval: 1.0)
                // ── ③ 回读确认（trim 后比较）──
                let after = try lightroomAppState()
                if Self.currentPopupValue(in: after, id: "Popup_ImportPreset")?
                    .trimmingCharacters(in: .whitespaces) == preset {
                    return true
                }
            } else {
                // 没找到就收起下拉，避免挡住后续操作
                _ = try? callTool("press_key", arguments: [
                    "app": "com.adobe.LightroomClassicCC7", "key": "Escape",
                ])
            }
            Thread.sleep(forTimeInterval: 0.6)
        }
        return false
    }

    /// 取某个 popup 的当前 value（形如 `[63] AXPopUpButton value="  社团导入" id=Popup_ImportPreset`）。
    static func currentPopupValue(in text: String, id: String) -> String? {
        for line in text.split(separator: "\n") where line.contains("id=\(id)") {
            let s = String(line)
            guard let v = s.range(of: "value=\"") else { continue }
            let rest = s[v.upperBound...]
            guard let close = rest.firstIndex(of: "\"") else { continue }
            return String(rest[..<close])
        }
        return nil
    }

    /// 按 trim 后的标题找元素索引（菜单项标题常带前导空格）。
    static func parseElementIndex(in text: String, trimmedTitle title: String) -> String? {
        for line in text.split(separator: "\n") {
            let s = String(line)
            guard let q1 = s.range(of: "\""), let q2 = s.range(of: "\"", range: q1.upperBound..<s.endIndex) else { continue }
            let raw = String(s[q1.upperBound..<q2.lowerBound])
            if raw.trimmingCharacters(in: .whitespaces) == title {
                if let idx = firstBracketIndex(in: s) { return idx }
            }
        }
        return nil
    }

    /// 从 AX 树文本里按 `id=xxx` 找元素索引（形如 `[123] AXPopUpButton ... id=Popup_ImportPreset`）。
    static func parseElementIndex(in text: String, idEquals id: String) -> String? {
        for line in text.split(separator: "\n") {
            if line.contains("id=\(id)") || line.contains("id=\"\(id)\"") {
                if let idx = firstBracketIndex(in: String(line)) { return idx }
            }
        }
        return nil
    }

    /// 从 AX 树文本里按标题找元素索引（形如 `[123] AXMenuItem "社团导入" ...`）。
    static func parseElementIndex(in text: String, titleEquals title: String) -> String? {
        for line in text.split(separator: "\n") {
            let s = String(line)
            if s.contains("\"\(title)\"") || s.contains("value=\"\(title)\"") {
                if let idx = firstBracketIndex(in: s) { return idx }
            }
        }
        return nil
    }

    /// 取行首 `[N]` 里的 N。
    private static func firstBracketIndex(in line: String) -> String? {
        guard let open = line.firstIndex(of: "["), let close = line[open...].firstIndex(of: "]") else { return nil }
        let num = line[line.index(after: open)..<close]
        return Int(num).map(String.init)
    }

    // MARK: - 高层封装：固定流程用的按键与选片

    /// 激活 Lightroom 到前台（Cmd+A / Cmd+U 必须落在 LR 上）。
    @discardableResult
    func activateLightroom() throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", "tell application \"Adobe Lightroom Classic\" to activate"]
        try? proc.run()
        proc.waitUntilExit()
        Thread.sleep(forTimeInterval: 1.5)
        return "activated"
    }

    /// 发一个按键（xdotool 风格，如 "super+u" / "d" / "r"）。
    @discardableResult
    func pressKey(_ key: String) throws -> String {
        try callTool("press_key", arguments: [
            "app": "com.adobe.LightroomClassicCC7",
            "key": key,
        ])
    }

    /// 修改照片模块里「全选」：
    /// 实测坑——面板滑块在无选中照片时是 DISABLED，光发 Cmd+A 会落空。
    /// 顺序：D 进模块 → G 回网格 → 点一格抢焦点 → Cmd+A → D 回模块。
    @discardableResult
    func selectAllInDevelop() throws -> String {
        _ = try pressKey("d")
        Thread.sleep(forTimeInterval: 1.5)
        _ = try pressKey("g")
        Thread.sleep(forTimeInterval: 1.5)
        _ = try callTool("click", arguments: [
            "app": "com.adobe.LightroomClassicCC7",
            "x": 430, "y": 260,
        ])
        Thread.sleep(forTimeInterval: 1.5)
        _ = try pressKey("super+a")
        Thread.sleep(forTimeInterval: 2.0)
        _ = try pressKey("d")
        Thread.sleep(forTimeInterval: 1.5)
        return "selected"
    }

    /// 全选 + **验证**：只有 Develop 面板不再 DISABLED（= 真的选上了照片）才算成功。
    /// 为什么必须验证：面板滑块在无选中照片时是 DISABLED，光发 Cmd+A 会静默落空，
    /// 后面的 Cmd+U 就作用在"零张照片"上——这是最隐蔽的假成功之一。
    @discardableResult
    func selectAllInDevelopVerified() throws -> Bool {
        _ = try? pressKey("Escape")
        Thread.sleep(forTimeInterval: 0.6)
        _ = try pressKey("g")                       // 图库网格
        Thread.sleep(forTimeInterval: 1.5)
        _ = try callTool("click", arguments: [
            "app": "com.adobe.LightroomClassicCC7", "x": 430, "y": 260,   // 点一格抢焦点
        ])
        Thread.sleep(forTimeInterval: 1.2)
        _ = try pressKey("super+a")                 // 全选
        Thread.sleep(forTimeInterval: 1.8)
        _ = try pressKey("d")                       // 回修改照片
        Thread.sleep(forTimeInterval: 2.0)

        // 验证：基本面板的滑块必须处于可用状态
        let t = try lightroomAppState()
        let enabled = t.contains("id=Exposure2012") && !Self.isDisabledLine(in: t, id: "Exposure2012")
        return enabled
    }

    /// 判断某个 id 的那一行是否带 DISABLED。
    static func isDisabledLine(in text: String, id: String) -> Bool {
        for line in text.split(separator: "\n") where line.contains("id=\(id)") {
            if line.contains("DISABLED") { return true }
        }
        return false
    }

    // MARK: - 高层封装：模块保证 / 自动修齐 / 协助消隐（实测流程固化）

    /// 确保 LR 停在**图库**模块。
    /// 为什么必须有这一步（实测踩坑）：
    ///   * `triggerImportUI` 在「修改照片」模块下**静默失效**（不弹窗、不报错）；
    ///   * 「协助消隐 / 主体聚焦 / 应用批处理操作」只在图库模块存在，
    ///     在修改照片模块的 AX 树里**完全找不到**，极易误判成"面板被隐藏"。
    /// 另：光按 G 不一定切得过去，必须先把焦点交给主窗口（点一下网格区）再按 G。
    @discardableResult
    func ensureLibraryModule(timeout: TimeInterval = 30) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var attempt = 0
        while Date() < deadline {
            attempt += 1
            // 先把可能卡住的裁剪/模态清掉 —— 实测：卡在裁剪工具里时按 G 不会切模块，
            // 表现就是「协助消隐 面板整个找不到 / 无法进入图库」。
            _ = try? pressKey("Escape")
            Thread.sleep(forTimeInterval: 0.8)
            // 焦点交给主窗口（网格区/图像区各试一次）
            let pt = attempt % 2 == 0 ? (430, 260) : (700, 400)
            _ = try callTool("click", arguments: [
                "app": "com.adobe.LightroomClassicCC7", "x": pt.0, "y": pt.1,
            ])
            Thread.sleep(forTimeInterval: 1.2)
            _ = try pressKey("g")
            Thread.sleep(forTimeInterval: 1.0)
            _ = try? pressKey("g")
            Thread.sleep(forTimeInterval: 2.0)
            let t = try lightroomAppState()
            if t.contains("协助消隐") || t.contains("图库过滤器") { return true }
        }
        return false
    }

    /// R 进裁剪 → 点真实「自动」（自动拉直/修齐）→ R 退出裁剪。
    /// 实测：该按钮在 AX 树里是 `AXButton "自动" desc="自动拉直照片。"`，可直接 AXPress，
    /// 不必猜坐标；全选状态下对全部选中照片生效。
    @discardableResult
    func cropAutoStraightenAll() throws -> Bool {
        for attempt in 1...3 {
            _ = try? pressKey("Escape")             // 清掉上一次可能残留的裁剪/模态
            Thread.sleep(forTimeInterval: 0.8)
            _ = try pressKey("d")                   // 确保在修改照片模块
            Thread.sleep(forTimeInterval: 1.5)
            _ = try pressKey("r")                   // 进裁剪
            Thread.sleep(forTimeInterval: 2.5)
            let text = try lightroomAppState()
            if let idx = Self.parseButtonIndex(in: text, descContains: "自动拉直照片") {
                _ = try callTool("click", arguments: [
                    "app": "com.adobe.LightroomClassicCC7", "element_index": idx,
                ])
                Thread.sleep(forTimeInterval: 8)    // 等批量拉直
                _ = try pressKey("r")               // 退出裁剪
                Thread.sleep(forTimeInterval: 2)
                return true
            }
            // 没进去：再按一次 R 或 Escape 复位后重试
            _ = try? pressKey("r")
            Thread.sleep(forTimeInterval: 1.5)
        }
        return false
    }

    /// 回图库全选 → 跑协助消隐 → 等结果 → 应用批处理操作写旗标。
    /// 安全红线：只勾「应用标志」，**绝不碰「删除照片」**（它会真的删照片）。
    @discardableResult
    func runAssistedCulling(waitForResult: TimeInterval = 240) throws -> String {
        guard try ensureLibraryModule() else { return "无法进入图库模块" }
        _ = try pressKey("super+a")
        Thread.sleep(forTimeInterval: 2)

        let deadline = Date().addingTimeInterval(waitForResult)
        var resultLine = ""
        while Date() < deadline {
            let t = try lightroomAppState()
            if let m = Self.cullingResultLine(in: t) { resultLine = m; break }
            Thread.sleep(forTimeInterval: 8)
        }
        guard !resultLine.isEmpty else { return "协助消隐未在限定时间内出结果" }

        let t2 = try lightroomAppState()
        guard let batchIdx = Self.parseButtonIndex(in: t2, titleEquals: "应用批处理操作") else {
            return "\(resultLine)（未找到应用批处理操作按钮）"
        }
        _ = try callTool("click", arguments: [
            "app": "com.adobe.LightroomClassicCC7", "element_index": batchIdx,
        ])
        Thread.sleep(forTimeInterval: 2.5)

        let dialog = try lightroomAppState()
        let toCheck = Self.uncheckedApplyFlagIndices(in: dialog)
        for idx in toCheck {
            _ = try callTool("click", arguments: [
                "app": "com.adobe.LightroomClassicCC7", "element_index": idx,
            ])
            Thread.sleep(forTimeInterval: 0.9)
        }
        let dialog2 = try lightroomAppState()
        if let okIdx = Self.parseButtonIndex(in: dialog2, titleEquals: "确认") {
            _ = try callTool("click", arguments: [
                "app": "com.adobe.LightroomClassicCC7", "element_index": okIdx,
            ])
            Thread.sleep(forTimeInterval: 3)
            return resultLine + (toCheck.isEmpty ? "（旗标已就位）" : "（已写入旗标）")
        }
        return resultLine + "（未找到确认按钮）"
    }

    /// 从 AX 树里按按钮标题找索引。
    static func parseButtonIndex(in text: String, titleEquals title: String) -> String? {
        for line in text.split(separator: "\n") where line.contains("AXButton") {
            let s = String(line)
            if s.contains("\"\(title)\"") { return firstBracketIndex(in: s) }
        }
        return nil
    }

    /// 从 AX 树里按 desc 包含关系找按钮索引（LR 部分按钮只有 desc 没有 title）。
    static func parseButtonIndex(in text: String, descContains fragment: String) -> String? {
        for line in text.split(separator: "\n") where line.contains("AXButton") && line.contains(fragment) {
            if let idx = firstBracketIndex(in: String(line)) { return idx }
        }
        return nil
    }

    /// 取「选择 N 张照片，拒绝 M 张照片」这一行。
    static func cullingResultLine(in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "value=\"(选择 \\d+ 张照片，拒绝 \\d+ 张照片)\"") else { return nil }
        guard let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    /// 找「应用标志」且当前 value="0" 的复选框索引（**不返回「删除照片」**）。
    static func uncheckedApplyFlagIndices(in text: String) -> [String] {
        var out: [String] = []
        for line in text.split(separator: "\n") {
            let s = String(line)
            guard s.contains("AXCheckBox"), s.contains("应用标志"), s.contains("value=\"0\"") else { continue }
            if let idx = firstBracketIndex(in: s) { out.append(idx) }
        }
        return out
    }

    // MARK: - 高层封装：逐张读取「协助消隐」判定原因

    /// 一张照片在 Lightroom「辅助筛选信息」面板里的全部判定信号。
    struct CullSignals {
        var subjectScore: Int?      // 主体聚焦 分数（0-100，越低越模糊）
        var eyeScore: Int?          // 眼睛聚焦 分数
        var eyesOpen: Bool?         // 眼睛在睁着：true=已开启 / false=可能未开启 / nil=未检测到人脸
        var faceFound: Bool         // 是否检测到人脸
        var docLabel: String?       // 文档判定：屏幕快照/文档/图形/照片
        var fileName: String?       // 元数据面板里的文件名（用于和 app 内照片对齐）
    }

    /// 按 Right 方向键 `step` 次后读取当前选中照片的判定信号。
    /// LR 的辅助筛选信息面板：分数行只有选中**图片**时才出现（视频/无分析时缺失）。
    func readCullSignals(afterRightPresses step: Int) throws -> CullSignals {
        for _ in 0..<max(step, 1) {
            _ = try callTool("press_key", arguments: [
                "app": "com.adobe.LightroomClassicCC7",
                "key": "Right",
            ])
            Thread.sleep(forTimeInterval: 0.35)   // LR 选中切换 + 面板刷新
        }
        Thread.sleep(forTimeInterval: 0.6)        // 等分析面板稳定
        let text = try lightroomAppState()
        return Self.parseCullSignals(from: text)
    }

    /// 从 AX 树文本解析辅助筛选信息面板。
    /// 面板结构：主体聚焦/眼睛聚焦/眼睛在睁着/人脸 标签行，值行在其右侧（x>1320）。
    static func parseCullSignals(from text: String) -> CullSignals {
        var s = CullSignals(faceFound: false)
        // 逐行扫描，建立"标签 → 其后最近出现的值"映射（面板行序固定）
        let lineRegex = #"\[(\d+)\] AXStaticText (?:value="([^"]*)" )?desc="([^"]*)" value="([^"]*)" @(\d+),(\d+)"#
        let rows: [(label: String, value: String, x: Int, y: Int)] = {
            var out: [(String, String, Int, Int)] = []
            guard let regex = try? NSRegularExpression(pattern: lineRegex) else { return [] }
            regex.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { m, _, _ in
                guard let m, m.numberOfRanges >= 7 else { return }
                func g(_ i: Int) -> String {
                    guard let r = Range(m.range(at: i), in: text) else { return "" }
                    return String(text[r])
                }
                let value = g(4), desc = g(3), x = Int(g(5)) ?? 0, y = Int(g(6)) ?? 0
                // 标签行：x≈1194 的 "主体聚焦/眼睛聚焦/眼睛在睁着/文档/人脸"
                // 值行：x≥1320 且 y 与标签接近
                if x >= 1190, x <= 1210, ["主体聚焦","眼睛聚焦","眼睛在睁着","人脸"].contains(value) {
                    out.append((value, "LABEL", x, y))
                } else if x >= 1320, y >= 790, y <= 1000 {
                    out.append(("VALUE", value, x, y))
                }
            }
            return out
        }()
        // 把值分配给最近的上方标签
        var lastLabel: String?
        var labelY = 0
        for row in rows {
            if row.label != "VALUE" {
                lastLabel = row.label
                labelY = row.y
            } else if let label = lastLabel, abs(row.y - labelY) < 40 {
                switch label {
                case "主体聚焦": s.subjectScore = Int(row.value.replacingOccurrences(of: "分数：", with: ""))
                case "眼睛聚焦": s.eyeScore = Int(row.value.replacingOccurrences(of: "分数：", with: ""))
                case "眼睛在睁着":
                    s.eyesOpen = row.value.contains("已开启") ? true : (row.value.contains("开启") ? nil : false)
                case "人脸": break
                default: break
                }
            }
        }
        // 人脸/文档信息在 desc 或 value 里找
        if text.contains("未找到人脸") { s.faceFound = false; if s.eyesOpen == nil {} } else { s.faceFound = true }
        for doc in ["屏幕快照", "收据", "图形", "数字图形"] where text.contains(doc) {
            s.docLabel = doc; break
        }
        // 元数据面板文件名：AXTextField value="…" @1216,约1917
        if let m = text.range(of: #"AXTextField value="([^"]+)" @1216,19\d\d"#, options: .regularExpression) {
            let seg = text[m]
            if let q = seg.range(of: "value=\"") , let e = seg.range(of: "\" @1216") {
                s.fileName = String(seg[q.upperBound..<e.lowerBound])
            }
        }
        return s
    }

    /// 根据信号推断"建议排除原因"（与 LR 协助消隐面板勾选的阈值一致：聚焦 ≥40）。
    static func rejectReasons(for s: CullSignals) -> [String] {
        var reasons: [String] = []
        if let v = s.subjectScore, v < 40 { reasons.append("主体聚焦 \(v)（<40 模糊）") }
        if let v = s.eyeScore, v < 40 { reasons.append("眼睛聚焦 \(v)（<40 失焦）") }
        if s.faceFound, s.eyesOpen == false { reasons.append("眼睛可能闭合") }
        if let d = s.docLabel, d != "照片" { reasons.append("文档类：\(d)") }
        return reasons
    }

    /// 从 AX 树文本里解析「导入」按钮的 element_index 与 disabled 状态。
    private func parseImportButton(in text: String) throws -> (index: Int, disabled: Bool)? {
        let linePattern = #"\[(\d+)\]\s+AXButton\s+"导入""#
        guard let regex = try? NSRegularExpression(pattern: linePattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let rng = Range(match.range(at: 1), in: text),
              let idx = Int(text[rng]) else { return nil }
        let range = Range(match.range, in: text)!
        let lineText = String(text[text.lineRange(for: range)])
        return (idx, lineText.contains("DISABLED"))
    }

    func stop() {
        lock.lock()
        if let p = process { p.terminate(); self.process = nil }
        initialized = false
        lock.unlock()
    }
}

enum CUAError: Error {
    case noProcess
    case noResponse(String)
    case toolError(String)
    case rpcError(String)
    case unexpected
}
