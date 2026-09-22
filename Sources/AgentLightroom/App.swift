import SwiftUI
import AppKit

@main
struct AgentLightroomApp: App {
    @StateObject private var model = WorkstationModel()

    /// 命令行启动参数（CLI 入口，绕开一切 GUI 自动化）：
    ///   Agent Lightroom --import <文件夹>   启动即导入该文件夹并进入选片
    ///   Agent Lightroom --source <文件夹>   只载入不发导入命令
    /// 这样 shell / 脚本 / dsh-cua 都能全自动驱动，不必模拟点击"选择文件夹"。
    /// 命令行入口解析结果（静态存放，避免在 init 里捕获 self）。
    /// 应用时机在 ContentView 的 onAppear，那时 SwiftUI 状态已就绪。
    static let cliLaunch: (url: URL, autoImport: Bool)? = {
        let args = Array(CommandLine.arguments.dropFirst())
        var source: String?
        var autoImport = false
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--import":
                autoImport = true
                if i + 1 < args.count { source = args[i + 1]; i += 1 }
            case "--source":
                if i + 1 < args.count { source = args[i + 1]; i += 1 }
            default:
                // 也支持直接传一个路径：open -a "Agent Lightroom" --args /path/to/folder
                if source == nil, !args[i].hasPrefix("-") { source = args[i] }
            }
            i += 1
        }
        guard let path = source else { return nil }
        return (URL(fileURLWithPath: (path as NSString).expandingTildeInPath), autoImport)
    }()

    var body: some Scene {
        WindowGroup("Agent Lightroom") { ContentView(model: model).frame(minWidth: 1180, minHeight: 760) }
        .windowResizability(.contentSize)
    }
}

enum WorkspacePage: String, CaseIterable, Identifiable {
    case importPage = "导入", cull = "选片", work = "工作", export = "导出"
    var id: String { rawValue }
    var symbol: String { ["导入":"arrow.down.circle", "选片":"square.grid.2x2", "工作":"slider.horizontal.3", "导出":"arrow.up.circle"][rawValue] ?? "circle" }
}

struct PhotoItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    var selected = true
    var rejected = false
    var master = false
    var cullingState = "pending"
    /// Lightroom 协助消隐的建议原因（保留为空；排除时列出触发的判定条件）。
    var cullReasons: [String] = []
    /// 拍摄信息（状态行显示）：拍摄者/焦距/时间/光圈/快门/ISO。
    var artist = ""
    var focalLength = ""
    var shotTime = ""
    var aperture = ""
    var shutter = ""
    var iso = ""

    /// 状态行文本：有值才显示，避免空字段堆一串分隔符。
    var shootingInfoLine: String {
        let parts: [String?] = [
            artist.isEmpty ? nil : "拍摄者 \(artist)",
            focalLength.isEmpty ? nil : "焦距 \(focalLength)",
            shotTime.isEmpty ? nil : shotTime,
            aperture.isEmpty ? nil : "光圈 \(aperture)",
            shutter.isEmpty ? nil : "快门 \(shutter)",
            iso.isEmpty ? nil : "ISO \(iso)",
        ]
        let shown = parts.compactMap { $0 }
        return shown.isEmpty ? "拍摄信息读取中…" : shown.joined(separator: "   ")
    }
}

@MainActor
final class WorkstationModel: ObservableObject {
    @Published var page: WorkspacePage = .importPage
    @Published var sourceURL: URL?
    @Published var exportURL: URL?
    @Published var photos: [PhotoItem] = []
    @Published var currentIndex = 0
    @Published var status = "等待导入素材"
    @Published var bridgeOnline = false
    @Published var cullingMessage = "等待 Lightroom 协助消隐结果"
    /// 原因采集进度（如 "37 / 153"）；空串表示未在采集。
    @Published var reasonScanProgress = ""
    private var isScanningReasons = false
    @Published var chat = ["我可以帮你执行导入、选片和调色。先选择一个照片文件夹。"]
    @Published var prompt = ""
    @Published var exposure = 0.0
    @Published var temperature = 0.0
    @Published var contrast = 0.0
    @Published var background = 0.0
    private var bridgeTimer: Timer?

    var currentPhoto: PhotoItem? { photos.indices.contains(currentIndex) ? photos[currentIndex] : nil }
    var keptCount: Int { photos.filter { $0.selected && !$0.rejected }.count }

    func chooseSource() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        sourceURL = url; status = "正在导入 Lightroom：\(url.lastPathComponent)"; loadPhotos(from: url); importIntoLightroom()
    }

    /// 设定导入源并（可选）立即发起导入。
    /// 图形界面的「选择文件夹」与命令行 `--import <path>` 都汇入这里，
    /// 保证用户手动操作与自动化走**完全相同**的代码路径。
    func setSource(_ url: URL, startImport: Bool) {
        sourceURL = url
        status = "正在导入 Lightroom：\(url.lastPathComponent)"
        loadPhotos(from: url)
        if startImport { importIntoLightroom() }
    }

    func loadPhotos(from url: URL) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentTypeKey]
        let urls = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys)?.allObjects as? [URL] ?? []
        let imageURLs = urls.filter { ["jpg", "jpeg", "png", "heic", "tif", "tiff", "dng", "nef", "arw", "cr2"].contains($0.pathExtension.lowercased()) }
        photos = imageURLs.map { PhotoItem(url: $0) }; currentIndex = 0
        status = photos.isEmpty ? "文件夹中没有识别到照片" : "已载入 \(photos.count) 张照片"
    }

    func importIntoLightroom() {
        guard let sourceURL else { return }
        // SDK 打开导入窗口并预选源；LR 无「提交导入」SDK API，
        // 由 dsh-cua（自家 MCP，直读 AXUIElement）定位并点击「导入」按钮完成全自动导入。
        sendBridge(["type": "import", "source": sourceURL.path]) { [weak self] ok, detail in
            guard let self else { return }
            DispatchQueue.main.async {
                if !ok {
                    self.status = "⚠️ 打开导入窗口失败：\(detail)"
                    return
                }
                self.status = "已打开导入窗口，正在用 dsh-cua 自动点击『导入』…"
                self.autoImportViaCUA()
            }
        }
    }

    /// 经 dsh-cua 驱动 LR 导入对话框：轮询等待对话框出现 → 定位「导入」按钮 → 点击。
    private func autoImportViaCUA() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                // 规格第 1 条：导入前先选好导入预设「社团导入」。
                // 预设不存在/选不上不阻塞导入，但状态里如实说明。
                var presetNote = ""
                do {
                    let okPreset = try CUAClient.shared.selectImportPreset(named: "社团导入")
                    presetNote = okPreset ? "（预设：社团导入）" : "（⚠️ 未选上预设「社团导入」）"
                } catch {
                    presetNote = "（⚠️ 预设选择异常：\(error.localizedDescription)）"
                }
                let result = try CUAClient.shared.clickLightroomImport(timeout: 20)
                let detail = CUAClient.shared.lastNotFoundDetail
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch result {
                    case .clicked:
                        self.status = "✅ 已通过 dsh-cua 自动提交导入\(presetNote)，等待 Lightroom 写入目录"
                    case .disabled:
                        self.status = "⚠️ 导入按钮为灰禁用状态：源文件夹里没有可导入的新照片（可能都已导入过）"
                    case .notFound:
                        self.status = "⚠️ 20 秒内未找到『导入』按钮（\(detail)）。若提示 AX 树为空，请到 系统设置→隐私与安全性→辅助功能 勾选 Agent Lightroom"
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.status = "⚠️ dsh-cua 驱动失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func chooseExport() { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; if panel.runModal() == .OK { exportURL = panel.url; status = "导出到 \(panel.url?.lastPathComponent ?? "")" } }

    func decide(_ value: String) {
        guard photos.indices.contains(currentIndex) else { return }
        photos[currentIndex].rejected = value == "reject"; photos[currentIndex].selected = value != "reject"; photos[currentIndex].master = value == "master"
        sendBridge(["type":"decision", "value":value]) { [weak self] ok, detail in
            guard let self else { return }
            DispatchQueue.main.async {
                self.status = ok ? (value == "reject" ? "已发送：标记淘汰，等待 Lightroom 确认" : "已发送：标记保留，等待 Lightroom 确认") : "⚠️ 选片失败：\(detail)"
            }
        }
    }

    func applyAdjustments() {
        sendBridge(["type":"adjust", "exposure": exposure * 20, "contrast": contrast * 20, "temperature": temperature, "tint": 0]) { [weak self] ok, detail in
            guard let self else { return }
            DispatchQueue.main.async {
                self.status = ok ? "已发送调色参数，等待 Lightroom 应用" : "⚠️ 调色失败：\(detail)"
            }
        }
    }

    func sendPrompt() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines); guard !text.isEmpty else { return }
        chat.append("你：\(text)"); prompt = ""
        if text.contains("背景") { background = -0.5; chat.append("Agent：已解析为背景压暗，并保留人物曝光。") }
        else if text.contains("亮") || text.contains("曝光") { exposure = 0.35; chat.append("Agent：已解析为主体提亮，曝光 +0.35。") }
        else { chat.append("Agent：已记录调色意图，可继续用滑块微调。") }
    }

    func sync() {
        sendBridge(["type":"sync", "count":keptCount]) { [weak self] ok, detail in
            guard let self else { return }
            DispatchQueue.main.async { self.status = ok ? "已发送批量同步，等待 Lightroom 应用" : "⚠️ 同步失败：\(detail)" }
        }
    }
    func export() {
        sendBridge(["type":"export", "count":keptCount, "path":exportURL?.path ?? ""]) { [weak self] ok, detail in
            guard let self else { return }
            DispatchQueue.main.async { self.status = ok ? "已发送导出任务，等待 Lightroom 执行" : "⚠️ 导出失败：\(detail)" }
        }
    }

    func checkBridge() {
        guard let url = URL(string: "http://127.0.0.1:8765/health") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] _, response, _ in
            let online = (response as? HTTPURLResponse)?.statusCode == 200
            Task { @MainActor in
                guard let self else { return }
                let wasOffline = !self.bridgeOnline
                self.bridgeOnline = online
                // 仅在「刚连上」时拉一次目录快照；不要每次心跳都发 snapshot，
                // 否则会与 LR 插件（遍历整个 catalog，较慢）形成命令积压风暴。
                if online && wasOffline { self.sendBridge(["type":"snapshot"]) { _, _ in } }
                if online { self.refreshCullingState() }
            }
        }.resume()
    }

    func startBridgePolling() {
        bridgeTimer?.invalidate()
        bridgeTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkBridge() }
        }
    }

    /// 逐张采集 Lightroom 协助消隐的建议原因：
    /// 用 dsh-cua 在 LR 里按 Right 键逐张导航，读「辅助筛选信息」面板的
    /// 主体聚焦/眼睛聚焦分数、眼睛开合、文档判定，换算成人类可读原因。
    /// 每 4 张发一次 snapshot 让旗标回灌（旗标由 LR 批处理已落库，这里只补原因）。
    func startReasonScan() {
        guard !isScanningReasons else { return }
        guard !photos.isEmpty else { status = "没有照片可采集原因"; return }
        isScanningReasons = true
        status = "开始逐张采集排除原因（LR 需保持前台）"
        // 主线程取快照值再进后台，避免跨线程读 @Published。
        let total = photos.count
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var scanned = 0
            // LR 网格当前选中位置未知，先按一次 Right 保证至少前移一格；
            // 采集顺序与网格顺序一致，用文件名对齐回写。
            var step = 1
            while scanned < total {
                do {
                    let signals = try CUAClient.shared.readCullSignals(afterRightPresses: step)
                    step = 1   // 之后每次只前进一格
                    scanned += 1
                    let reasons = CUAClient.rejectReasons(for: signals)
                    let fname = signals.fileName ?? ""
                    let done = scanned          // 捕获值，避免跨线程引用可变变量
                    DispatchQueue.main.async {
                        self.reasonScanProgress = "\(done) / \(total)"
                        self.applyReasons(fileName: fname, reasons: reasons)
                    }
                    // 每 5 张发一次 snapshot，保持旗标同步
                    if done % 5 == 0 {
                        self.postSnapshot()
                    }
                } catch {
                    let msg = error.localizedDescription
                    DispatchQueue.main.async {
                        self.status = "原因采集中断：\(msg)"
                        self.isScanningReasons = false
                        self.reasonScanProgress = ""
                    }
                    return
                }
            }
            let finished = scanned
            DispatchQueue.main.async {
                self.status = "✅ 原因采集完成（\(finished) 张）"
                self.isScanningReasons = false
                self.reasonScanProgress = ""
            }
        }
    }

    /// 把原因按文件名写回对应照片（忽略大小写；找不到就丢弃，不污染其它照片）。
    @MainActor
    private func applyReasons(fileName: String, reasons: [String]) {
        guard !fileName.isEmpty,
              let idx = photos.firstIndex(where: { $0.url.lastPathComponent.caseInsensitiveCompare(fileName) == .orderedSame })
        else { return }
        photos[idx].cullReasons = reasons
    }

    private func postSnapshot() {
        sendBridge(["type": "snapshot"]) { _, _ in }
    }

    // MARK: - 正式后期固定流程（完全确定，无 AI 决策）

    /// LR 渲染预览目录（由 `tools/al-previews` 从 LR 预览缓存批量导出）。
    /// 选片/工作页的预览读它而不是磁盘原文件——这样看到的是「基础修图完成后」的画面。
    ///
    /// 为什么不用插件 thumbs：本机 LR 15.5 上 `photo:requestJpegThumbnail` 的
    /// sync 形态返回空、async 形态每张白等超时，实测 169/169 全失败；
    /// 而 LR 的预览缓存文件本身就是标准 JPEG 且天然含 develop 设定，
    /// 走 `tools/al-previews` 稳定且快（172/172 成功）。
    static let lrThumbDir = URL(fileURLWithPath: "/tmp/al-previews")

    /// LR 渲染预览的磁盘路径（无则返回 nil，调用方回退原文件）。
    static func lrPreviewURLIfAny(fileName: String) -> URL? {
        let u = lrThumbDir.appendingPathComponent(fileName + ".jpg")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// 一键正式后期（规格的"完全固定程序"，点一次跑完）：
    ///   ① 导入（选预设「社团导入」并点导入）
    ///   ② 自动调整 Cmd+U → 自动修齐 R→自动 → 自动变换 Upright
    ///   ③ 回图库全选跑协助消隐并落旗标
    ///   ④ 导出 LR 渲染预览 + 回灌旗标到工作台
    ///   ⑤ 完成后发系统通知
    func runFullProgram() {
        guard let sourceURL else { status = "请先选择导入来源"; return }
        let folder = sourceURL.path
        setStatus("① 导入：正在打开 Lightroom 导入窗…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                _ = try CUAClient.shared.activateLightroom()
                // 导入前置：必须在图库模块，否则 triggerImportUI 静默失效
                let inLibrary = try CUAClient.shared.ensureLibraryModule()
                if !inLibrary { self.setStatus("⚠️ 无法进入图库模块，导入可能不弹窗") }

                _ = try? self.sendBridgeSync(["type": "import", "source": folder], timeout: 30)
                Thread.sleep(forTimeInterval: 3)

                let presetOK = (try? CUAClient.shared.selectImportPreset(named: "社团导入")) ?? false
                let click = try CUAClient.shared.clickLightroomImport(timeout: 90)
                switch click {
                case .clicked: self.setStatus(presetOK ? "② 已选预设「社团导入」，导入已提交，等待入库…" : "② ⚠️ 预设未选上，导入已提交，等待入库…")
                case .disabled:
                    // 源里没有新照片（例如已经导入过）：不是错误，直接按现有目录继续跑流程。
                    self.setStatus("② 源里没有新照片，按现有目录继续…")
                case .notFound: self.setStatus("⚠️ 未找到导入按钮（\(CUAClient.shared.lastNotFoundDetail)）"); return
                }

                // 等入库完成：目录照片数增长后连续 3 次稳定即视为完成
                let before = self.catalogCount()
                var last = before, stable = 0
                let deadline = Date().addingTimeInterval(900)
                while Date() < deadline {
                    Thread.sleep(forTimeInterval: 10)
                    let now = self.catalogCount()
                    if now > before {
                        stable = (now == last) ? stable + 1 : 0
                        last = now
                        if stable >= 3 { break }
                    }
                }
                self.setStatus("③ 导入完成（目录 \(self.catalogCount()) 张），开始修图…")
                DispatchQueue.main.async { self.runFixedPipeline() }
            } catch {
                self.setStatus("⚠️ 一键流程中断：\(error.localizedDescription)")
            }
        }
    }

    /// 读 bridge /health 里的目录照片数（导入完成的判据）。
    private func catalogCount() -> Int {
        guard let url = URL(string: "http://127.0.0.1:8765/health"),
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = obj["culling"] as? [[String: Any]] else { return 0 }
        return rows.count
    }

    /// 固定流程总编排（与规格一一对应）：
    ///  ② 修改照片：抢焦点 → 全选 → Cmd+U 自动调整 → 变换自动（SDK 写 Upright=Auto）
    ///  ③ 回图库取 LR 渲染预览（thumbs）+ 刷新协助消隐旗标
    ///  ④ 完成后发系统通知「基础修改完成」
    func runFixedPipeline() {
        guard let sourceURL else { status = "请先选择导入来源"; return }
        let folder = sourceURL.path
        setStatus("① 基础修图：切到修改照片并全选…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                // ── ② 修改照片：抢焦点 → 全选 → Cmd+U 自动调整 ──
                // 关键教训：Develop 面板滑块在「无选中照片」时是 DISABLED，
                // 直接发 Cmd+A 会落空，必须先点一张照片把焦点交给胶片条。
                _ = try CUAClient.shared.activateLightroom()

                // ① 前置：图库模块（带验证+重试）
                self.setStatus("① 确保 Lightroom 处于图库模块…")
                let libOK = self.retryStep("进入图库模块", attempts: 3) {
                    try CUAClient.shared.ensureLibraryModule(timeout: 20)
                }
                if !libOK { self.setStatus("⚠️ 无法进入图库模块（后续步骤可能受影响），继续尝试…") }

                // ② 全选并验证「Develop 面板已启用」= 确实选上了照片
                self.setStatus("② 全选照片…")
                let selOK = self.retryStep("全选照片", attempts: 3) {
                    try CUAClient.shared.selectAllInDevelopVerified()
                }

                // ③ Cmd+U 自动调整：用 tone 回读比对判定是否真的写入，失败重试
                self.setStatus("③ 应用自动调整（Cmd+U，带回读验证）…")
                let baseTone = (try? self.probeTone(folder: folder)) ?? ""
                var toneOK = false
                for attempt in 1...3 {
                    _ = try CUAClient.shared.pressKey("super+u")
                    Thread.sleep(forTimeInterval: 14)
                    let after = (try? self.probeTone(folder: folder)) ?? ""
                    if !after.isEmpty && after != baseTone { toneOK = true; break }
                    self.setStatus("⚠️ 自动调整第 \(attempt)/3 次回读无变化，重试…")
                    _ = try? CUAClient.shared.selectAllInDevelopVerified()
                }

                // ④ 规格②后半：全选 → R → 自动（自动修齐）
                self.setStatus("④ 应用自动修齐（R → 自动，带重试）…")
                let straightened = self.retryStep("自动修齐（R→自动）", attempts: 3) {
                    try CUAClient.shared.cropAutoStraightenAll()
                }

                // ⑤ 变换 Upright：SDK 自带回读（routine done: Upright=Auto on N/M）
                self.setStatus("⑤ 应用自动变换（Upright，带回读）…")
                var routineResult = ""
                for _ in 1...2 {
                    routineResult = try self.sendBridgeSync(["type": "routine", "source": folder], timeout: 300)
                    if !routineResult.contains("0/") { break }
                }

                // ⑥ 协助消隐：结果串里出现「无法/未」就整体重试
                self.setStatus("⑥ 跑协助消隐（图库 · 全选）…")
                var cullResult = ""
                for attempt in 1...3 {
                    cullResult = try CUAClient.shared.runAssistedCulling()
                    if !cullResult.contains("无法") && !cullResult.contains("未在限定时间") && !cullResult.contains("未找到") { break }
                    self.setStatus("⚠️ 协助消隐第 \(attempt)/3 次未成功：\(cullResult)")
                    _ = try? CUAClient.shared.ensureLibraryModule(timeout: 20)
                }
                self.setStatus("⑦ 协助消隐：\(cullResult)。正在取 LR 渲染预览…")

                // LR 渲染预览：走 al-previews（LR 预览缓存批量导出）。
                // 不用插件 thumbs —— 本机实测那条路 169/169 全失败。
                let thumbsResult = try self.exportLRPreviews()
                self.setStatus("⑦ \(thumbsResult)。正在回灌旗标到工作台…")

                _ = try? self.sendBridgeSync(["type": "snapshot"], timeout: 180)

                // 规格收尾：回到 Lightroom（停图库 + 置于前台），
                // 让用户直接看到协助消隐后的筛选结果。
                _ = try? CUAClient.shared.ensureLibraryModule(timeout: 20)
                _ = try? CUAClient.shared.activateLightroom()
                self.setStatus("⑧ 已回到 Lightroom（图库），正在通知完成…")

                let n = self.photoCountOnMain()
                self.notifyBaseEditingDone(count: n)
                self.setStatus("✅ 基础修改完成（\(n) 张）"
                    + " 全选=\(selOK ? "OK" : "失败")"
                    + " 调整=\(toneOK ? "已写入" : "未见变化")"
                    + " 修齐=\(straightened ? "OK" : "跳过")"
                    + " 变换=\(routineResult)"
                    + " 消隐=\(cullResult)")
            } catch {
                self.setStatus("⚠️ 固定流程中断：\(error.localizedDescription)")
            }
        }
    }

    /// 读插件探针里的 tone 摘要（自动调整写入的判据）。
    /// 探针现在抽"真正的图片"（不是视频），所以这个比对是有意义的。
    private func probeTone(folder: String) throws -> String {
        let msg = try sendBridgeSync(["type": "probe", "source": folder], timeout: 90)
        guard let r = msg.range(of: "tone=[") else { return "" }
        let rest = msg[r.upperBound...]
        guard let end = rest.firstIndex(of: "]") else { return "" }
        return String(rest[..<end])
    }

    /// 带验证的重试骨架：action 返回 true 才算成功，否则重试 attempts 次。
    /// 用户明确要求：自动操作不稳定 → 每一步都要验证 + 失败重试，
    /// 绝不能"发出去了就当成功"（本项目反复栽在这一点上）。
    @discardableResult
    private func retryStep(_ name: String, attempts: Int = 3, pause: TimeInterval = 3,
                           _ action: () throws -> Bool) -> Bool {
        for i in 1...attempts {
            if (try? action()) == true { return true }
            self.setStatus("⚠️ \(name) 第 \(i)/\(attempts) 次未通过验证，重试…")
            Thread.sleep(forTimeInterval: pause)
        }
        return false
    }

    /// 调 tools/al-previews 把 LR 已渲染的预览批量导出到 /tmp/al-previews。
    /// 失败不抛错（预览缺失只是退化为原文件预览），但消息里如实说明。
    private func exportLRPreviews() throws -> String {
        let script = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Corp AI/Agent Lightroom/tools/al-previews")
        guard FileManager.default.isExecutableFile(atPath: script.path) else {
            return "al-previews 不可执行，预览退回原文件"
        }
        let proc = Process()
        proc.executableURL = script
        proc.arguments = ["--clean"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8) ?? ""
        // 取最后一行"导出 N 张 → …"作为可读结果
        let last = out.split(separator: "\n").last.map(String.init) ?? out
        return proc.terminationStatus == 0 ? last : "预览导出未完全成功：\(last)"
    }

    private func photoCountOnMain() -> Int {
        if Thread.isMainThread { return photos.count }
        return DispatchQueue.main.sync { photos.count }
    }

    private func setStatus(_ text: String) {
        DispatchQueue.main.async { self.status = text }
    }

    /// 同步版命令发送：固定流程必须按顺序等上一步真的完成。
    /// 发送后轮询 /state 的 lastResult，直到插件回报非 starting 状态。
    private func sendBridgeSync(_ command: [String: Any], timeout: TimeInterval) throws -> String {
        guard let url = URL(string: "http://127.0.0.1:8765/command"),
              let body = try? JSONSerialization.data(withJSONObject: command) else {
            throw NSError(domain: "AgentLightroom", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法构造命令"])
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in sem.signal() }.resume()
        _ = sem.wait(timeout: .now() + 10)

        let deadline = Date().addingTimeInterval(timeout)
        var lastMessage = ""
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 2)
            guard let stateURL = URL(string: "http://127.0.0.1:8765/state"),
                  let data = try? Data(contentsOf: stateURL),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let lr = obj["lastResult"] as? [String: Any],
                  let st = lr["status"] as? String,
                  let msg = lr["message"] as? String else { continue }
            lastMessage = msg
            if st != "starting" {
                if st == "error" {
                    throw NSError(domain: "AgentLightroom", code: 2, userInfo: [NSLocalizedDescriptionKey: msg])
                }
                return msg
            }
        }
        return lastMessage.isEmpty ? "超时未回报" : lastMessage
    }

    /// 系统通知：基础修改完成（用户明确要求的「通知我」）。
    private func notifyBaseEditingDone(count: Int) {
        DispatchQueue.main.async { self.status = "✅ 基础修改完成（\(count) 张）" }
        let script = "display notification \"\(count) 张照片已完成自动调整与自动变换\" with title \"Agent Lightroom\" subtitle \"基础修改完成\" sound name \"Glass\""
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        try? proc.run()
        NSSound.beep()
    }

    func refreshCullingState() {
        guard let url = URL(string: "http://127.0.0.1:8765/state") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let rows = object["culling"] as? [[String: Any]] else { return }
            // 注意：culling 来自整个目录快照（上千条），不同文件夹里的同名文件会
            // 产生重复键。Dictionary(uniqueKeysWithValues:) 遇到重复键会直接 trap
            // （EXC_BREAKPOINT / SIGTRAP），曾导致 app 一启动就崩溃、窗口都不出现。
            // 这里改为容忍重复（后者覆盖前者）。
            var states: [String: String] = [:]
            var shooting: [String: [String]] = [:]
            for row in rows {
                guard let name = row["name"] as? String, let flag = row["flag"] as? String else { continue }
                states[name] = flag
                if let info = row["shooting"] as? [String] { shooting[name] = info }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                var changed = 0
                for index in self.photos.indices {
                    let key = self.photos[index].url.lastPathComponent
                    if let flag = states[key] {
                        self.photos[index].cullingState = flag
                        self.photos[index].rejected = flag == "reject"
                        self.photos[index].selected = flag != "reject"
                        changed += 1
                    }
                    if let info = shooting[key], info.count >= 6 {
                        self.photos[index].artist = info[0]
                        self.photos[index].focalLength = info[1]
                        self.photos[index].shotTime = info[2]
                        self.photos[index].aperture = info[3]
                        self.photos[index].shutter = info[4]
                        self.photos[index].iso = info[5]
                    }
                }
                self.cullingMessage = changed > 0 ? "已同步 Lightroom 协助消隐：\(changed) 张" : "等待 Lightroom 写入协助消隐结果"
            }
        }.resume()
    }

    /// 发送命令到桥接服务，并读取 HTTP 回执。成功 = 200 且桥接返回 ok；
    /// 桥接离线 / 命令入队失败 / 插件执行报错都会在 completion 里给到诚实的 detail。
    private func sendBridge(_ command: [String: Any], completion: (@Sendable (Bool, String) -> Void)? = nil) {
        guard let url = URL(string: "http://127.0.0.1:8765/command"), let body = try? JSONSerialization.data(withJSONObject: command) else {
            completion?(false, "无法构造命令"); return
        }
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = body
        URLSession.shared.dataTask(with: request) { data, response, error in
            let httpOK = (response as? HTTPURLResponse)?.statusCode == 200
            var ok = httpOK
            var detail = "已入队，等待 Lightroom 回应"
            if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let o = obj["ok"] as? Bool { ok = ok && o }
                if let q = obj["queued"] as? Int, q >= 0 { detail = "命令已送达桥接（队列 \(q)）" }
            }
            if !httpOK { detail = error?.localizedDescription ?? "桥接服务未响应（请确认 bridge 已启动）" }
            completion?(ok, detail)
        }.resume()
    }
}

struct ContentView: View {
    @ObservedObject var model: WorkstationModel
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 18) {
                Label("Agent Lightroom", systemImage: "camera.aperture").font(.title2.bold()).padding(.bottom, 12)
                Text("智能摄影后期工作站").font(.caption).foregroundStyle(.secondary)
                ForEach(WorkspacePage.allCases) { page in Button { model.page = page } label: { Label(page.rawValue, systemImage: page.symbol).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.borderedProminent).tint(model.page == page ? .accentColor : .gray.opacity(0.18)).foregroundStyle(model.page == page ? .white : .primary) }
                Spacer(); Label(model.bridgeOnline ? "Lightroom Bridge 在线" : "本地演示模式", systemImage: model.bridgeOnline ? "circle.fill" : "circle.dashed").font(.caption).foregroundStyle(model.bridgeOnline ? .green : .secondary)
            }.padding(20).navigationSplitViewColumnWidth(220)
        } detail: {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading) {
                        Text("当前项目").font(.caption).foregroundStyle(.secondary)
                        Text(model.page.rawValue).font(.title.bold())
                    }
                    Spacer()
                    // 状态行：选片/工作页显示当前照片的拍摄信息（用户指定），
                    // 其它页显示流程进度文字。两者都给，避免信息丢失。
                    VStack(alignment: .trailing, spacing: 2) {
                        if model.page == .cull || model.page == .work {
                            Text(model.currentPhoto?.shootingInfoLine ?? "拍摄信息读取中…")
                                .font(.callout).monospacedDigit()
                        }
                        Text(model.status).font(.caption).foregroundStyle(.secondary)
                    }
                    Button("检查 Bridge") { model.checkBridge() }
                }.padding(20)
                Divider(); pageBody.frame(maxWidth: .infinity, maxHeight: .infinity); Divider(); filmstrip.padding(12)
            }.background(Color(nsColor: .windowBackgroundColor))
        }.onAppear {
            model.checkBridge(); model.startBridgePolling()
            // CLI 入口：--import <dir> / <dir> 启动即导入，绕开 GUI 选文件夹。
            NSLog("[AgentLightroom] argv = \(CommandLine.arguments)")
            if let launch = AgentLightroomApp.cliLaunch {
                NSLog("[AgentLightroom] CLI launch -> \(launch.url.path) autoImport=\(launch.autoImport)")
                model.setSource(launch.url, startImport: launch.autoImport)
            } else {
                NSLog("[AgentLightroom] no CLI launch args")
            }
        }
    }

    @ViewBuilder private var pageBody: some View {
        switch model.page { case .importPage: ImportView(model: model); case .cull: CullView(model: model); case .work: WorkView(model: model); case .export: ExportView(model: model) }
    }
    private var filmstrip: some View { VStack(alignment: .leading, spacing: 6) { Text(model.cullingMessage).font(.caption).foregroundStyle(.secondary); ScrollView(.horizontal) { HStack { ForEach(Array(model.photos.enumerated()), id: \.element.id) { index, photo in Button { model.currentIndex = index } label: { ZStack(alignment: .bottomLeading) { PhotoThumb(url: photo.url).frame(width: 76, height: 54).overlay(RoundedRectangle(cornerRadius: 5).stroke(index == model.currentIndex ? Color.accentColor : Color.clear, lineWidth: 2)); if photo.cullingState == "reject" { Text("排除").font(.system(size: 9, weight: .bold)).padding(3).background(.red, in: RoundedRectangle(cornerRadius: 3)).foregroundStyle(.white) } else if photo.cullingState == "select" { Text("精选").font(.system(size: 9, weight: .bold)).padding(3).background(.green, in: RoundedRectangle(cornerRadius: 3)).foregroundStyle(.white) } } } }.buttonStyle(.plain) } } } }
}

struct ImportView: View {
    @ObservedObject var model: WorkstationModel

    var body: some View {
        HStack(spacing: 18) {
            VStack(spacing: 18) {
                Image(systemName: "folder.badge.plus").font(.system(size: 54))
                Text("选择照片文件夹").font(.title2.bold())
                Text(model.sourceURL?.path ?? "尚未选择导入来源")
                    .foregroundStyle(.secondary).lineLimit(2)
                Button("选择文件夹") { model.chooseSource() }
                    .buttonStyle(.borderedProminent)
                    // 显式辅助功能标识：SwiftUI 在这些嵌套布局下有时不会把 Button
                    // 暴露到 AX 树里，导致外部自动化（dsh-cua）找不到它。加上标识后
                    // 一定能被读取与点击，用户与自动化走同一条路径。
                    .accessibilityIdentifier("import.chooseFolder")
                    .accessibilityLabel("选择文件夹")
                Text("或把文件夹拖到这里")
                    .font(.caption).foregroundStyle(.tertiary)
                    .accessibilityIdentifier("import.dropHint")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            // 拖放：用户最自然的"指定来源"方式，也让自动化可以用
            // `open -a "Agent Lightroom" <文件夹>` 或拖拽绕过 GUI 选文件夹。
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                model.setSource(url, startImport: true)
                return true
            }

            VStack(alignment: .leading, spacing: 16) {
                Text("导入选项").font(.headline)
                Toggle("构建智能预览", isOn: .constant(true))
                Toggle("应用镜头校正", isOn: .constant(true))
                Toggle("跳过疑似重复", isOn: .constant(false))
                Divider()
                Text("素材数量").foregroundStyle(.secondary)
                Text("\(model.photos.count) 张").font(.title.bold())
                // 唯一入口（用户要求收敛）：点一次跑完
                // 导入 → 自动调整 → 自动拉直 → 自动 Upright → 协助消隐 → 回到 Lightroom
                Button("导入初筛并进入选片") {
                    guard model.sourceURL != nil else { model.chooseSource(); return }
                    model.runFullProgram()
                    model.page = .cull
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("pipeline.runAll")
                .accessibilityLabel("导入初筛并进入选片")
            }
            .frame(width: 280).padding(22)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(24)
    }
}

struct CullView: View {
    @ObservedObject var model: WorkstationModel

    /// Lightroom「协助消隐」的判定维度（与 LR 图库模块右栏面板一一对应）。
    /// 这些是 LR 在本机自动分析的结果，app 只做忠实展示，不自行评分。
    private static let cullingCriteria = [
        "主体聚焦 ≥40（拒绝主体模糊）",
        "眼睛聚焦 ≥40（拒绝眼睛失焦）",
        "仅检测到人眼的照片",
        "眼睛在睁着（拒绝闭眼）",
        "曝光问题排除（过曝/欠曝）",
        "废片排除（误拍/严重模糊）",
        "文档排除（文档/收据/截屏）",
    ]

    /// 按 Lightroom 旗标分组的照片列表：精选 / 排除 / 未标记。
    private var selects: [PhotoItem] { model.photos.filter { $0.cullingState == "select" } }
    private var rejects: [PhotoItem] { model.photos.filter { $0.cullingState == "reject" } }
    private var unflagged: [PhotoItem] { model.photos.filter { $0.cullingState != "select" && $0.cullingState != "reject" } }

    var body: some View {
        HStack(spacing: 18) {
            // 主预览：优先展示精选照片，让用户第一眼看到"该留的"
            VStack {
                if let p = currentPreview {
                    PhotoThumb(url: p.url).aspectRatio(4/3, contentMode: .fit).background(.black)
                    Text(p.url.lastPathComponent).font(.headline)
                    Text(previewBadge).font(.caption).foregroundStyle(.secondary)
                } else {
                    ContentUnavailableView("尚未导入照片", systemImage: "photo")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(18)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 10) {
                Text("Lightroom 协助消隐结果").font(.title2.bold())
                Text("由 Lightroom 在本机自动分析，旗标实时回灌")
                    .font(.caption).foregroundStyle(.secondary)

                // 三档计数总览
                HStack(spacing: 12) {
                    StatBadge(label: "精选", count: selects.count, color: .green)
                    StatBadge(label: "排除", count: rejects.count, color: .red)
                    StatBadge(label: "未标记", count: unflagged.count, color: .gray)
                }

                // 使用的判定条件（与 LR 面板勾选项一致）
                DisclosureGroup("判定条件（\(Self.cullingCriteria.count) 项）") {
                    ForEach(Self.cullingCriteria, id: \.self) { Text("• " + $0).font(.caption).foregroundStyle(.secondary) }
                }.font(.callout)

                // 逐张原因采集
                Button {
                    model.startReasonScan()
                } label: {
                    Label(
                        model.reasonScanProgress.isEmpty ? "采集每张图的排除原因" : "采集中… \(model.reasonScanProgress)",
                        systemImage: "text.magnifyingglass"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.reasonScanProgress.isEmpty)

                Divider()

                // 精选列表（可点击预览）
                if !selects.isEmpty {
                    Text("精选照片").font(.headline).foregroundStyle(.green)
                    ForEach(selects) { row($0, color: .green) }
                }
                // 未标记列表
                if !unflagged.isEmpty {
                    Text("未标记（LR 未给出建议）").font(.headline).foregroundStyle(.secondary)
                    ForEach(unflagged.prefix(6)) { row($0, color: .gray) }
                    if unflagged.count > 6 { Text("…以及 \(unflagged.count - 6) 张").font(.caption).foregroundStyle(.tertiary) }
                }
                // 排除列表：每张带原因
                if !rejects.isEmpty {
                    DisclosureGroup("排除照片（\(rejects.count) 张）") {
                        ForEach(rejects.prefix(20)) { rejectRow($0) }
                        if rejects.count > 20 { Text("…以及 \(rejects.count - 20) 张").font(.caption).foregroundStyle(.tertiary) }
                    }
                }
                Spacer()
            }
            .frame(width: 340)
            .padding(20)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(24)
    }

    private var currentPreview: PhotoItem? {
        if model.photos.indices.contains(model.currentIndex), model.photos[model.currentIndex].cullingState != "pending" {
            return model.photos[model.currentIndex]
        }
        return selects.first ?? model.currentPhoto
    }
    private var previewBadge: String {
        guard let p = currentPreview else { return "" }
        switch p.cullingState {
        case "select": return "✅ Lightroom 建议保留"
        case "reject": return "🚫 Lightroom 建议排除" + (p.cullReasons.isEmpty ? "" : "：" + p.cullReasons.joined(separator: "；"))
        default: return "⚪ 未标记"
        }
    }

    private func row(_ photo: PhotoItem, color: Color) -> some View {
        Button {
            if let idx = model.photos.firstIndex(where: { $0.id == photo.id }) { model.currentIndex = idx }
        } label: {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(photo.url.lastPathComponent).lineLimit(1)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).font(.caption)
    }

    /// 排除行：文件名 + 逐条原因（灰底原因标签；未采集到原因时给占位说明）。
    private func rejectRow(_ photo: PhotoItem) -> some View {
        Button {
            if let idx = model.photos.firstIndex(where: { $0.id == photo.id }) { model.currentIndex = idx }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 7, height: 7)
                    Text(photo.url.lastPathComponent).lineLimit(1).font(.caption)
                }
                if photo.cullReasons.isEmpty {
                    Text("（尚未采集原因）").font(.caption2).foregroundStyle(.tertiary)
                } else {
                    ForEach(photo.cullReasons, id: \.self) { reason in
                        Text("· " + reason)
                            .font(.caption2)
                            .foregroundStyle(.red.opacity(0.85))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 三档计数徽标：数字醒目、按语义着色。
struct StatBadge: View {
    let label: String
    let count: Int
    let color: Color
    var body: some View {
        VStack(spacing: 2) {
            Text("\(count)").font(.title2.bold()).foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct WorkView: View { @ObservedObject var model: WorkstationModel; var body: some View { HStack(spacing: 18) { VStack { if let p = model.currentPhoto { PhotoThumb(url: p.url).aspectRatio(4/3, contentMode: .fit).brightness(model.exposure).contrast(1 + model.contrast).overlay(Color.orange.opacity(max(0, model.background) * 0.25)) } else { ContentUnavailableView("尚未导入照片", systemImage: "photo") }; Spacer() }.frame(maxWidth: .infinity).padding(18).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12)); VStack(alignment: .leading, spacing: 12) { Text("AI 调色助理").font(.title2.bold()); ScrollView { VStack(alignment: .leading) { ForEach(model.chat, id: \.self) { Text($0).padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8)) } } }; HStack { TextField("描述调色思路…", text: $model.prompt); Button("发送") { model.sendPrompt() } }.textFieldStyle(.roundedBorder); Divider(); Text("快速修改").font(.headline); SliderRow(title: "曝光", value: $model.exposure, range: -1...1); SliderRow(title: "白平衡", value: $model.temperature, range: -100...100); SliderRow(title: "对比", value: $model.contrast, range: -1...1); SliderRow(title: "背景压暗", value: $model.background, range: -1...1); HStack { Button("应用当前照片") { model.applyAdjustments() }; Button("同步到相似组") { model.sync() } }.buttonStyle(.borderedProminent) }.frame(width: 340).padding(20).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12)) }.padding(24) } }

struct ExportView: View { @ObservedObject var model: WorkstationModel; var body: some View { HStack(spacing: 18) { VStack(spacing: 16) { Image(systemName: "folder").font(.system(size: 54)); Text(model.exportURL?.path ?? "尚未选择导出文件夹").foregroundStyle(.secondary).lineLimit(2); Button("选择导出文件夹") { model.chooseExport() }.buttonStyle(.borderedProminent) }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12)); VStack(alignment: .leading, spacing: 16) { Text("导出设置").font(.title2.bold()); Picker("格式", selection: .constant("JPEG")) { Text("JPEG").tag("JPEG"); Text("TIFF").tag("TIFF") }.pickerStyle(.menu); Picker("色彩空间", selection: .constant("sRGB")) { Text("sRGB").tag("sRGB"); Text("Adobe RGB").tag("Adobe RGB") }.pickerStyle(.menu); Text("精选照片：\(model.keptCount) 张"); Spacer(); Button("确认并发送到 Lightroom") { model.export() }.buttonStyle(.borderedProminent) }.frame(width: 300).padding(22).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12)) }.padding(24) } }

struct SliderRow: View { let title: String; @Binding var value: Double; let range: ClosedRange<Double>; var body: some View { VStack(alignment: .leading) { HStack { Text(title); Spacer(); Text(String(format: "%.2f", value)).foregroundStyle(.secondary).monospacedDigit() }; Slider(value: $value, in: range) } } }
struct PhotoThumb: View { let url: URL; var body: some View { Group { if let lr = WorkstationModel.lrPreviewURLIfAny(fileName: url.lastPathComponent), let image = NSImage(contentsOf: lr) { Image(nsImage: image).resizable().scaledToFit() } else if let image = NSImage(contentsOf: url) { Image(nsImage: image).resizable().scaledToFit() } else { ZStack { Color.black; Image(systemName: "photo").foregroundStyle(.secondary) } } }.clipShape(RoundedRectangle(cornerRadius: 8)) } }
