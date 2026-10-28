import Foundation
import Observation
import UIKit


@MainActor @Observable
final class ClassroomController {
    let translator = DeepSeekTranslation()
    let library: ClassLibrary
    var state = ClassroomState.idle
    var document: ClassDocument?
    var lines: [CaptionLine] = []
    var status = "选择课程，开始听课"
    var errorMessage: String?
    var meter: Float = 0
    var audioSeconds = 0.0
    var inputRoute = ""
    var eventCount = 0
    var busy: Bool { state != .idle }
    var canPause: Bool { state == .recording || state == .paused }
    var displayLines: [CaptionLine] {
        guard var doc = document else { return lines }
        doc.lines = lines; doc.semanticUnits = translator.units
        return doc.displayLines
    }
    @ObservationIgnored private let capture = LocalSpeechCapture()
    @ObservationIgnored private var ledger = TranscriptLedger()
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var baseOffset = 0.0
    @ObservationIgnored private var activeAudioPart: UUID?
    @ObservationIgnored private var pendingFinalStatus: String?
    @ObservationIgnored private var finalCaptureError: String?
    @ObservationIgnored private var captureWasStarted = false
    @ObservationIgnored private var cancelStart = false
    @ObservationIgnored private var backgrounded = false
    @ObservationIgnored private var captureID = UUID()
    @ObservationIgnored private var backgroundSaveTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var backgroundSaveToken = UUID()

    init(library: ClassLibrary) { self.library = library }

    func start(title: String, course: Course, saveAudio: Bool, fileURL: URL? = nil) async {
        var doc = ClassDocument(title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? course.name + "课堂" : title, course: course)
        doc.source = fileURL == nil ? "microphone" : "imported"; doc.model = translator.model
        doc.semanticUnits = []; doc.recordingEnabled = saveAudio
        if fileURL == nil { doc.audioParts = [] }
        await openCapture(doc, initialFile: fileURL)
    }
    func resume(_ saved: ClassDocument) async {
        guard let latest = library.documents.first(where: { $0.id == saved.id }), latest.isResumable else { return }
        var doc = latest; doc.prepareContinuation()
        await openCapture(doc, initialFile: nil)
    }
    private func openCapture(_ saved: ClassDocument, initialFile: URL?) async {
        guard !busy else { return }
        guard UIApplication.shared.applicationState != .background else { errorMessage = "请返回前台再开始听课。"; return }
        captureID = UUID(); let token = captureID
        state = .preparing; cancelStart = false; backgrounded = false; errorMessage = nil; pendingFinalStatus = nil; finalCaptureError = nil
        status = "正在准备本地法语识别…"
        var doc = saved; doc.status = "preparing"; doc.endedAt = nil
        translator.cancel(); translator.captions = doc.captions; translator.units = doc.semanticUnits ?? []
        lines = doc.lines; ledger = TranscriptLedger(lines: lines); meter = 0; audioSeconds = doc.duration; eventCount = 0
        baseOffset = doc.duration; activeAudioPart = nil; document = doc; captureWasStarted = false
        do {
            try library.save(doc)
            let folder = library.folder(doc.id)
            var audioURL: URL?
            if doc.source == "imported" {
                if let initialFile {
                    let access = initialFile.startAccessingSecurityScopedResource()
                    defer { if access { initialFile.stopAccessingSecurityScopedResource() } }
                    let ext = initialFile.pathExtension.lowercased().filter { $0.isLetter || $0.isNumber }
                    let target = folder.appendingPathComponent("audio").appendingPathExtension(ext.isEmpty ? "caf" : String(ext.prefix(8)))
                    try FileManager.default.copyItem(at: initialFile, to: target)
                    doc.audioFilename = target.lastPathComponent; audioURL = target
                } else { audioURL = library.audioURL(doc) }
                guard audioURL != nil else { throw CaptureError("未找到原始音频，请先在课堂中关联录音。") }
            } else {
                let filename = doc.recordingEnabled == true ? "audio-" + UUID().uuidString + ".caf" : nil
                if let filename { audioURL = folder.appendingPathComponent(filename); if doc.audioFilename == nil { doc.audioFilename = filename } }
                let part = ClassAudioPart(filename: filename, start: baseOffset, duration: 0)
                if doc.audioParts == nil { doc.audioParts = [] }
                doc.audioParts?.append(part); activeAudioPart = part.id
            }
            document = doc; try library.save(doc)
            let event: @MainActor @Sendable (Double, Double, String, Bool, Double?) -> Void = { [weak self] start, duration, text, final, confidence in
                guard let self, self.busy, self.captureID == token else { return }
                let received = CaptionEvent(start: start, duration: duration, text: text, isFinal: final,
                    receivedSeconds: 0, deliveryLagSeconds: nil, confidence: confidence, afterStop: self.state == .stopping)
                self.ledger.receive(ClassContinuation.offset(received, by: self.baseOffset))
                self.lines = self.ledger.lines; self.eventCount += 1
                self.audioSeconds = max(self.audioSeconds, self.baseOffset + start + duration)
                self.translator.observe(self.lines)
            }
            let meter: @MainActor @Sendable (Float, Double, Double) -> Void = { [weak self] level, seconds, _ in
                guard let self, self.busy, self.captureID == token else { return }
                self.meter = level; self.audioSeconds = max(self.audioSeconds, self.baseOffset + seconds)
            }
            let failure: @MainActor @Sendable (String) -> Void = { [weak self] message in
                guard let self, self.busy, self.captureID == token else { return }
                self.errorMessage = message
                Task { guard self.captureID == token else { return }; await self.stop() }
            }
            if doc.source == "imported", let audioURL {
                captureWasStarted = true
                try await capture.startFile(audioURL, fromSeconds: baseOffset, event: event, origin: { _ in }, meter: meter,
                    failure: failure, completed: { [weak self] in Task { guard let self, self.captureID == token else { return }; await self.stop() } })
                inputRoute = "导入音频 · 从保存位置继续"
            } else {
                captureWasStarted = true
                inputRoute = try await capture.startMicrophone(recordingURL: audioURL,
                    event: event, origin: { _ in }, meter: meter, failure: failure)
            }
            state = .recording
            var seed = doc; seed.lines = lines
            translator.restore(seed, allowBackground: doc.source == "microphone", live: true)
            translator.observe(lines)
            if cancelStart { await stop(); return }
            UIApplication.shared.isIdleTimerDisabled = true; status = "正在听课"
            try persist()
            saveTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    guard let self, self.busy else { return }
                    self.saveNow()
                }
            }
        } catch {
            await completeFailedPreparation(error)
        }
    }

    private func completeFailedPreparation(_ failure: Error) async {
        state = .stopping; status = "启动未完成，正在保留当前内容…"
        beginBackgroundSaveIfNeeded(); defer { endBackgroundSave() }
        saveTask?.cancel(); saveTask = nil
        await capture.stop(); updateDrainedPosition()
        if var snapshot = document {
            if !translator.units.isEmpty { snapshot.semanticUnits = translator.units }
            translator.freezeForSave(snapshot, lines: lines)
        }
        errorMessage = cancelStart ? "启动已取消，现有内容已保留。可稍后继续这节课。" : failure.localizedDescription
        document?.endedAt = Date(); finalCaptureError = errorMessage; pendingFinalStatus = "interrupted"
        UIApplication.shared.isIdleTimerDisabled = false
        _ = completeFinalSave()
    }
    private func updateDrainedPosition() {
        guard captureWasStarted else { return }
        audioSeconds = baseOffset + capture.drain.seconds(for: document?.source ?? "microphone")
    }

    func togglePause() {
        do {
            if state == .recording { capture.pause(); state = .paused; meter = 0; status = "已暂停，点击继续听课" }
            else if state == .paused { try capture.resume(); state = .recording; status = "正在听课" }
            UIApplication.shared.isIdleTimerDisabled = state == .recording
            saveNow()
        } catch { errorMessage = "无法恢复录音：\(error.localizedDescription)"; Task { await stop() } }
    }
    func bookmark(_ note: String = "课堂重点") {
        guard busy else { return }
        document?.bookmarks.append(ClassBookmark(seconds: audioSeconds, text: note)); saveNow()
    }
    func updateNotes(_ text: String) { document?.notes = text }
    func saveNow() {
        if pendingFinalStatus != nil { _ = completeFinalSave(); return }
        do { try persist() } catch { errorMessage = "自动保存失败：\(error.localizedDescription)。请检查 iPad 剩余空间并重试保存。" }
    }
    private func persist(statusOverride: String? = nil) throws {
        guard var doc = document else { return }
        doc.lines = lines; doc.captions = translator.captions; doc.duration = audioSeconds
        if doc.semanticUnits != nil { doc.semanticUnits = translator.units }
        if let id = activeAudioPart, let i = doc.audioParts?.firstIndex(where: { $0.id == id }) {
            let start = doc.audioParts?[i].start ?? baseOffset
            doc.audioParts?[i].duration = max(0, audioSeconds - start)
        }
        if let statusOverride { doc.status = statusOverride }
        else if busy {
            switch state {
            case .preparing: doc.status = "preparing"
            case .paused: doc.status = "paused"
            case .stopping: doc.status = "stopping"
            default: doc.status = "recording"
            }
        }
        doc.lastError = errorMessage; document = doc; try library.save(doc)
    }
    func stop() async { await finishClass(suspend: false) }
    func suspendAndExit() async {
        guard state == .paused else { return }
        await finishClass(suspend: true)
    }
    private func finishClass(suspend: Bool) async {
        if state == .preparing { cancelStart = true; capture.cancelPreparation(); status = "准备结束后将自动停止并保存…"; return }
        guard state == .recording || state == .paused else { return }
        state = .stopping; beginBackgroundSaveIfNeeded()
        defer { endBackgroundSave() }
        status = "正在保存本节课…"; saveTask?.cancel(); saveTask = nil
        saveNow()
        await capture.stop()
        updateDrainedPosition()
        if capture.stopTimedOut { errorMessage = "识别收尾超时，已保留现有原文，最后一段可能不完整。" }
        translator.flushSegmentation(finalLines: lines)
        if backgrounded { translator.cancel() } else { await translator.finish(timeout: suspend ? 6 : 25) }
        meter = 0; UIApplication.shared.isIdleTimerDisabled = false
        document?.endedAt = suspend ? nil : Date()
        pendingFinalStatus = suspend ? "suspended" : (errorMessage == nil ? "complete" : "interrupted")
        finalCaptureError = errorMessage
        updateDrainedPosition()
        _ = completeFinalSave()
    }
    @discardableResult private func completeFinalSave() -> Bool {
        guard let desired = pendingFinalStatus else { return false }
        do {
            errorMessage = finalCaptureError
            try persist(statusOverride: desired)
            pendingFinalStatus = nil; activeAudioPart = nil; state = .idle; captureID = UUID()
            status = desired == "suspended" ? "已保存退出，可在课堂库继续这节课" : "课堂已保存"
            return true
        } catch {
            status = "保存未完成，请重试后再退出"
            errorMessage = "保存失败：\(error.localizedDescription)。收音已停止，当前内容仍保留，请点击重试保存。"
            return false
        }
    }
    private func beginBackgroundSaveIfNeeded() {
        guard backgrounded || UIApplication.shared.applicationState == .background,
              backgroundSaveTask == .invalid else { return }
        let token = UUID(); backgroundSaveToken = token
        // Only protect finite stop/save work after audio stops; never use this to keep a classroom alive.
        backgroundSaveTask = UIApplication.shared.beginBackgroundTask(withName: "Finish and save Clair class", expirationHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.backgroundSaveToken == token else { return }
                self.translator.cancel(); self.capture.cancelFinalization()
                self.translator.flushSegmentation(finalLines: self.lines)
                self.errorMessage = "系统的后台收尾时间已用尽，已保存现有内容；请返回后核对最后一段。"
                self.saveNow(); self.endBackgroundSave()
            }
        })
    }
    private func endBackgroundSave() {
        let task = backgroundSaveTask
        backgroundSaveTask = .invalid; backgroundSaveToken = UUID()
        if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
    }
    func applicationDidEnterBackground() {
        backgrounded = true
        UIApplication.shared.isIdleTimerDisabled = false
        switch ClassroomLifecycle.backgroundAction(state: state, source: document?.source ?? "") {
        case .continueMicrophone:
            status = "正在后台听课 · 返回后继续查看字幕"
        case .pauseImportedFile:
            capture.pause(); state = .paused; meter = 0
            status = "音频文件转写已暂停，返回后点击继续"
        case .keepPaused:
            status = "课堂保持暂停，返回后手动继续"
        case .cancelPreparation:
            cancelStart = true; capture.cancelPreparation()
            status = "准备中切入后台，已取消启动；请返回前台重新开始"
        case .saveOnly:
            if state == .stopping { beginBackgroundSaveIfNeeded() }
        }
        // A real running microphone supplies background execution. No silent playback or keep-alive task.
        if busy { saveNow() }
    }
    func applicationDidBecomeActive() {
        backgrounded = false
        UIApplication.shared.isIdleTimerDisabled = state == .recording
        if state == .recording { status = "正在听课" }
        else if state == .paused { status = "已暂停，点击继续听课" }
    }
}
