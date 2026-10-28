import Foundation
import Security
import Observation

enum DeepSeekKeychain {
    private static let service = "org.clairtest.deepseek"
    private static let account = "personal-api-key"
    static func read() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ key: String) throws {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let data = value.data(using: .utf8) else { throw CaptureError("请输入现有 DeepSeek 密钥。") }
        guard value.count >= 8, value.count <= 256, !value.contains(where: \.isWhitespace) else {
            throw CaptureError("密钥格式不正确，请仅粘贴完整 API 密钥，不要附带说明文字。")
        }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account]
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var add = query; add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw CaptureError("无法将密钥保存到此 iPad 的钥匙串。") }
        } else if update != errSecSuccess { throw CaptureError("无法更新钥匙串密钥。") }
    }
    static func remove() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
    }
}

@MainActor @Observable
final class DeepSeekTranslation {
    var captions: [ChineseCaption] = []
    var attempts: [TranslationAttempt] = []
    var units: [SemanticUnit] = []
    var reviewStatus = "本地滚动断句"
    var reviewEnabled = UserDefaults.standard.object(forKey: "Clair.enhancedSegmentation") as? Bool ?? true
    var status = "在设置中保存现有 DeepSeek 密钥后可启用中文"
    var hasKey = DeepSeekKeychain.read() != nil
    var pendingCount = 0
    var canRetry: Bool { accepting && (accountBlocked || captions.contains { $0.status == "failed" }) }
    var enabled = UserDefaults.standard.object(forKey: "deepseek.enabled") as? Bool ?? true
    var subject = UserDefaults.standard.string(forKey: "deepseek.subject") ?? "数学与物理"
    var glossary = UserDefaults.standard.string(forKey: "deepseek.glossary") ?? "代数：corps → 域，anneau → 环；分析：convergence simple → 逐点收敛，convergence uniforme → 一致收敛；物理：corps → 物体，quantité de mouvement → 动量，moment cinétique → 角动量，travail → 功，puissance → 功率"
    var model = UserDefaults.standard.string(forKey: "deepseek.model") ?? "deepseek-flash"
    var firstContentP50: Double? {
        percentile(attempts.filter { $0.status == "complete" }.compactMap { a in a.firstContentAtSeconds.map { $0 - a.requestedAtSeconds } }, 0.5)
    }
    var firstContentP95: Double? {
        percentile(attempts.filter { $0.status == "complete" }.compactMap { a in a.firstContentAtSeconds.map { $0 - a.requestedAtSeconds } }, 0.95)
    }
    @ObservationIgnored private var plan = TranslationPlan()
    @ObservationIgnored private var segmentation = RollingSegmentation()
    @ObservationIgnored private var reviewTask: Task<Void, Never>?
    @ObservationIgnored private var reviewGeneration = UUID()
    @ObservationIgnored private var firstPass = FirstPassCaptions()
    @ObservationIgnored private var revisionTasks: Set<UUID> = []
    @ObservationIgnored private var lastReview = ""
    @ObservationIgnored private var liveSession = false
    @ObservationIgnored private var corrections: [String: String] = [:]
    @ObservationIgnored private var inFlightSlices: [UUID: TranslationSlice] = [:]
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var runStarted = 0.0
    @ObservationIgnored private var accepting = false
    @ObservationIgnored private var accountBlocked = false
    @ObservationIgnored private var flushing = false
    @ObservationIgnored private var latestLines: [CaptionLine] = []
    @ObservationIgnored private var runSubject = ""
    @ObservationIgnored private var runGlossary = ""
    @ObservationIgnored private var runModel = ""
    // Retain credentials only for the live session; never serialize them or change Keychain accessibility.
    @ObservationIgnored private var runKey: String?
    @ObservationIgnored private var usesRunKey = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15; c.timeoutIntervalForResource = 25
        return URLSession(configuration: c)
    }()

    func saveSettings(key: String?) throws {
        if let key, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { try DeepSeekKeychain.save(key) }
        hasKey = DeepSeekKeychain.read() != nil
        model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.isEmpty { model = "deepseek-flash" }
        UserDefaults.standard.set(enabled, forKey: "deepseek.enabled")
        UserDefaults.standard.set(subject, forKey: "deepseek.subject")
        UserDefaults.standard.set(glossary, forKey: "deepseek.glossary")
        UserDefaults.standard.set(model, forKey: "deepseek.model")
        UserDefaults.standard.set(reviewEnabled, forKey: "Clair.enhancedSegmentation")
        status = hasKey ? "DeepSeek 设置已保存" : "未保存密钥，当前只显示法语"
    }
    func removeKey() { cancel(); DeepSeekKeychain.remove(); hasKey = false; status = "已移除此 iPad 保存的密钥" }

    func refreshSettings() {
        hasKey = DeepSeekKeychain.read() != nil
        enabled = UserDefaults.standard.object(forKey: "deepseek.enabled") as? Bool ?? true
        model = UserDefaults.standard.string(forKey: "deepseek.model") ?? "deepseek-flash"
        reviewEnabled = UserDefaults.standard.object(forKey: "Clair.enhancedSegmentation") as? Bool ?? true
    }

    func begin(allowBackground: Bool = false) {
        refreshSettings()
        cancel(); generation = UUID(); plan = TranslationPlan(); captions = []; attempts = []
        latestLines = []; pendingCount = 0; runStarted = ProcessInfo.processInfo.systemUptime
        accountBlocked = false; liveSession = true
        units = []; segmentation = RollingSegmentation(); corrections = [:]; lastReview = ""
        firstPass = FirstPassCaptions()
        reviewStatus = "本地滚动断句"
        runSubject = subject; runGlossary = glossary; runModel = model; flushing = false
        usesRunKey = allowBackground
        runKey = allowBackground ? DeepSeekKeychain.read() : nil
        accepting = enabled && hasKey && (!allowBackground || runKey != nil)
        status = !enabled ? "中文翻译已关闭" : (hasKey ? "等待法语短分句" : "未配置密钥，当前只显示法语")
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                self?.pump()
            }
        }
    }

    func restore(_ document: ClassDocument, allowBackground: Bool = false, only: Set<UUID>? = nil, live: Bool = false) {
        subject = document.course.subject; glossary = document.course.glossary
        begin(allowBackground: allowBackground)
        liveSession = live; corrections = document.correctedText ?? [:]
        units = document.semanticUnits ?? []
        segmentation = RollingSegmentation(seed: units)
        latestLines = document.lines
        let slices = document.translationSlices
        captions = document.captions
        synchronize(slices)
        for slice in slices {
            let complete = captions.first(where: { $0.id == slice.id }).map {
                $0.status == "complete" && $0.translatedFrench == slice.french
            } ?? false
            if complete || (only != nil && !only!.contains(UUID(uuidString: String(slice.id.prefix(36))) ?? UUID())) {
                plan.finish(id: slice.id, submitted: slice.french, success: true)
            }
        }
        flushing = !live; pump()
    }

    func observe(_ lines: [CaptionLine]) {
        latestLines = lines
        refreshSegmentation()
        pump()
    }
    func flushSegmentation(finalLines: [CaptionLine]? = nil) {
        if let finalLines {
            // Cancellation may precede Speech's last callback. Persist that tail without restarting API work.
            latestLines = finalLines
            rebuildSegmentation(flush: true)
        } else { refreshSegmentation(flush: true) }
    }
    /// Build a recoverable local snapshot after a failed preparation; never start API work.
    func freezeForSave(_ document: ClassDocument, lines: [CaptionLine]) {
        cancel()
        corrections = document.correctedText ?? [:]
        segmentation = RollingSegmentation(seed: document.semanticUnits ?? [])
        latestLines = lines; liveSession = true
        refreshSegmentation(flush: true)
        liveSession = false
    }
    private func refreshSegmentation(flush: Bool = false) {
        guard liveSession else { return }
        rebuildSegmentation(flush: flush)
    }
    private func rebuildSegmentation(flush: Bool) {
        firstPass.record(units: units, captions: captions)
        let previousUnits = units, previousCaptions = captions
        units = segmentation.update(latestLines, now: elapsed, flush: flush,
                                    translatedFragments: accepting ? firstPass.texts : nil)
        var slices = units.map(\.slice)
        var provisionalChinese: [String: String] = [:]
        let previousRows = Dictionary(previousCaptions.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        for unit in units where previousRows[unit.slice.id]?.french != unit.text {
            if let text = FirstPassCaptions.provisionalChinese(for: unit, previousUnits: previousUnits, captions: previousCaptions) {
                provisionalChinese[unit.slice.id] = text
            }
        }
        for i in slices.indices {
            if let text = corrections[String(slices[i].id.prefix(36))] { slices[i].french = text; slices[i].isFinal = true }
        }
        synchronize(slices, provisionalChinese: provisionalChinese)
    }
    private func synchronize(_ slices: [TranslationSlice], provisionalChinese: [String: String] = [:]) {
        let previous = Dictionary(captions.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        captions = slices.map { slice in
            var row = firstPass.completed(for: slice) ?? previous[slice.id] ?? ChineseCaption(id: slice.id, french: slice.french, audioStart: slice.audioStart)
            row.french = slice.french; row.sourceFinal = slice.isFinal; row.audioStart = slice.audioStart
            if row.provisionalFrench != slice.french { row.provisionalFrench = nil }
            if let translated = row.translatedFrench, translated != slice.french { row.status = "stale" }
            if let text = provisionalChinese[slice.id], !(row.status == "complete" && row.translatedFrench == slice.french) {
                row.chinese = text; row.provisionalFrench = slice.french; row.status = "stale"
            }
            return row
        }
        plan.observe(slices, now: elapsed, secondaryIDs: Set(captions.filter(\.isSemanticRepair).map(\.id)))
        for row in captions where row.status == "complete" && row.translatedFrench == row.french {
            plan.finish(id: row.id, submitted: row.french, success: true)
        }
        for (id, slice) in inFlightSlices where !slices.contains(where: { $0.id == slice.id && $0.french == slice.french }) {
            tasks[id]?.cancel()
        }
    }

    var elapsed: Double { ProcessInfo.processInfo.systemUptime - runStarted }
    private func pump() {
        refreshSegmentation()
        guard accepting else { return }
        if accountBlocked {
            status = attempts.last(where: { $0.status == "failed" })?.error ?? "请检查 DeepSeek 密钥和余额"
            return
        }
        pendingCount = plan.pendingCount
        if reviewTask != nil && plan.hasReadyFirstPass(now: elapsed, flush: flushing) {
            cancelBoundaryReview(); reviewStatus = "先出中文字幕 · 断句审查等待空闲"
        }
        while tasks.count + (reviewTask == nil ? 0 : 1) < 2,
              let item = plan.next(now: elapsed, flush: flushing,
                                   allowRevisions: !liveSession || flushing || revisionTasks.isEmpty) {
            let id = UUID(), token = generation
            let context = captions.prefix { $0.id != item.slice.id }.suffix(3).map(\.french)
            let index = attempts.count
            attempts.append(TranslationAttempt(id: id, unitID: item.slice.id, french: item.slice.french,
                requestedAtSeconds: elapsed, sourceObservedAtSeconds: item.firstObserved,
                model: runModel, status: "streaming", output: ""))
            update(item.slice.id) { $0.status = "streaming" }
            inFlightSlices[id] = item.slice
            if item.secondaryRepair { revisionTasks.insert(id) }
            tasks[id] = Task { [weak self] in
                guard let self else { return }
                await self.perform(item: item, index: index, context: context, token: token)
                guard self.generation == token else { return }
                self.tasks[id] = nil; self.inFlightSlices[id] = nil; self.revisionTasks.remove(id); self.pump()
            }
        }
        pendingCount = plan.pendingCount
        scheduleReview()
        let failed = captions.filter { $0.status == "failed" }.count
        status = failed > 0 ? "有 \(failed) 段翻译失败，可点重试" : (pendingCount > 4 ? "中文正在排队 \(pendingCount) 段，请留意是否持续积压" : (pendingCount > 0 ? "DeepSeek 翻译中 · \(pendingCount) 段" : "中文已跟上当前法语"))
    }

    private func cancelBoundaryReview() {
        reviewGeneration = UUID(); reviewTask?.cancel(); reviewTask = nil; lastReview = ""
    }
    private func scheduleReview() {
        guard liveSession, reviewEnabled, !flushing, reviewTask == nil, tasks.isEmpty,
              !plan.hasReadyFirstPass(now: elapsed),
              let window = segmentation.reviewWindow(now: elapsed), window.fingerprint != lastReview,
              window.fragments.dropFirst(window.firstMutable).allSatisfy({ firstPass.texts[$0.id] == $0.text }) else { return }
        lastReview = window.fingerprint
        let token = generation
        let reviewToken = UUID(); reviewGeneration = reviewToken
        reviewStatus = "前后两句审查中 · 字幕继续显示"
        reviewTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let key = (usesRunKey ? runKey : DeepSeekKeychain.read()) else { throw CaptureError("无可用密钥") }
                var request = URLRequest(url: DeepSeekProtocol.endpoint)
                request.httpMethod = "POST"; request.timeoutInterval = 8
                request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: BoundaryReviewProtocol.payload(window, model: runModel))
                let (data, response) = try await session.data(for: request)
                try Task.checkCancellation()
                guard generation == token, reviewGeneration == reviewToken else { return }
                guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 32_768 else {
                    throw CaptureError("断句审查不可用")
                }
                let decisions = try BoundaryReviewProtocol.parse(data)
                if segmentation.apply(decisions, for: window, now: elapsed) {
                    refreshSegmentation(); reviewStatus = "已审查邻近句 · 仅修订未锁定段落"
                } else { reviewStatus = "本地滚动断句 · 已忽略过时审查" }
            } catch {
                guard generation == token, reviewGeneration == reviewToken else { return }
                reviewStatus = "本地滚动断句 · 云端审查未完成"
            }
            guard generation == token, reviewGeneration == reviewToken else { return }
            reviewTask = nil; pump()
        }
    }

    private func perform(item: PlannedTranslation, index: Int, context: [String], token: UUID) async {
        let unit = item.slice
        let preserveProvisional = item.secondaryRepair && captions.contains {
            $0.id == unit.id && $0.provisionalFrench == unit.french && !$0.chinese.isEmpty
        }
        do {
            guard let key = (usesRunKey ? runKey : DeepSeekKeychain.read()) else { throw CaptureError("未找到此 iPad 的 DeepSeek 密钥。") }
            var request = URLRequest(url: DeepSeekProtocol.endpoint)
            request.httpMethod = "POST"
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: DeepSeekProtocol.payload(
                french: unit.french, context: context, subject: runSubject, glossary: runGlossary, model: runModel))
            let (bytes, response) = try await session.bytes(for: request)
            try Task.checkCancellation()
            guard generation == token else { return }
            guard let http = response as? HTTPURLResponse else { throw CaptureError("DeepSeek 未返回有效响应。") }
            guard http.statusCode == 200 else {
                if http.statusCode == 401 || http.statusCode == 402 { accountBlocked = true }
                throw CaptureError(Self.httpError(http.statusCode))
            }
            var output = "", finished = false, done = false, lastPaint = -1.0
            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard generation == token else { return }
                guard let delta = try DeepSeekProtocol.delta(line) else { continue }
                if delta.done { done = true; break }
                if let content = delta.content, !content.isEmpty {
                    if attempts[index].firstContentAtSeconds == nil { attempts[index].firstContentAtSeconds = elapsed }
                    output += content
                    if elapsed - lastPaint >= 0.06 {
                        lastPaint = elapsed
                        // Never attach an old response to a newer, changed French source.
                        if !preserveProvisional, plan.items[unit.id]?.slice.french == unit.french {
                            update(unit.id) { $0.chinese = output; $0.translatedFrench = unit.french; $0.provisionalFrench = nil }
                        }
                    }
                }
                if let reason = delta.finishReason {
                    guard reason == "stop" else { throw CaptureError("译文未完整结束（\(reason)），请重试。") }
                    finished = true
                }
                if let n = delta.promptTokens { attempts[index].inputTokens = n }
                if let n = delta.completionTokens { attempts[index].outputTokens = n }
            }
            try Task.checkCancellation()
            guard finished, done, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CaptureError("DeepSeek 流式响应中断，未收到完整译文。")
            }
            guard generation == token else { return }
            attempts[index].output = output; attempts[index].status = "complete"; attempts[index].completedAtSeconds = elapsed
            plan.finish(id: unit.id, submitted: unit.french, success: true)
            if plan.items[unit.id]?.slice.french == unit.french {
                update(unit.id) { $0.chinese = output; $0.translatedFrench = unit.french; $0.status = "complete"; $0.provisionalFrench = nil }
            }
        } catch {
            guard generation == token else { return }
            let message = error is CancellationError ? "翻译已取消" : ((error as? CaptureError)?.message ?? "DeepSeek 连接失败或超时，请检查网络并重试。")
            attempts[index].status = "failed"; attempts[index].error = message; attempts[index].completedAtSeconds = elapsed
            plan.finish(id: unit.id, submitted: unit.french, success: false)
            if plan.items[unit.id]?.slice.french == unit.french { update(unit.id) { $0.status = "failed" } }
        }
    }

    private func update(_ id: String, _ body: (inout ChineseCaption) -> Void) {
        if let index = captions.firstIndex(where: { $0.id == id }) { body(&captions[index]) }
    }
    func retryFailed() { accountBlocked = false; plan.retryFailed(); pump() }
    func finish(timeout: Double = 25) async {
        flushSegmentation()
        cancelBoundaryReview()
        guard accepting else { cancel(); return }
        if accountBlocked { cancel(); return }
        flushing = true; pump()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while pendingCount > 0 && ProcessInfo.processInfo.systemUptime < deadline {
            if accountBlocked { break }
            do { try await Task.sleep(for: .milliseconds(150)) } catch { break }
        }
        cancel()
    }
    func cancel() {
        runKey = nil; usesRunKey = false
        liveSession = false; cancelBoundaryReview(); revisionTasks.removeAll()
        inFlightSlices.removeAll()
        accepting = false; timer?.cancel(); timer = nil
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        // Keep current rows/results for review; callbacks may no longer update them.
        generation = UUID()
        for i in attempts.indices where attempts[i].status == "streaming" {
            attempts[i].status = "cancelled"; attempts[i].completedAtSeconds = elapsed
        }
        for i in captions.indices where ["streaming", "waiting", "stale"].contains(captions[i].status) { captions[i].status = "cancelled" }
        pendingCount = 0
        if !captions.isEmpty {
            let unfinished = captions.filter { $0.status != "complete" }.count
            status = unfinished > 0 ? "翻译已结束，\(unfinished) 段未完成；详情见导出报告" : "翻译已结束，结果已保留"
        }
    }
    private static func httpError(_ code: Int) -> String {
        switch code {
        case 401: "DeepSeek 密钥无效或已撤销，请在设置中更新。"
        case 402: "DeepSeek 账户余额不足。"
        case 429: "DeepSeek 请求限流，请稍后重试。"
        case 400, 404, 422: "DeepSeek 模型或请求配置不受支持，请检查模型名称。"
        default: "DeepSeek 服务暂不可用（HTTP \(code)）。"
        }
    }
}
