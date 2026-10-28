import SwiftUI
import AVFoundation
import Observation
import UniformTypeIdentifiers

@MainActor @Observable
final class ClassAudioPlayer {
    var playing = false
    var position = 0.0
    var duration = 0.0
    var error: String?
    @ObservationIgnored private var audio: AVAudioPlayer?
    @ObservationIgnored private var sources: [ClassAudioSource] = []
    @ObservationIgnored private var partIndex = 0
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var ownsSession = false
    func load(_ values: [ClassAudioSource]) {
        stop(); error = nil
        sources = values.sorted { $0.start < $1.start }.map { source in
            var source = source
            if let recording = try? AVAudioPlayer(contentsOf: source.url) { source.duration = recording.duration }
            return source
        }
        duration = sources.map { $0.start + $0.duration }.max() ?? 0
        if !sources.isEmpty { do { try selectPart(0, at: sources[0].start) } catch { self.error = error.localizedDescription } }
    }
    private func selectPart(_ index: Int, at seconds: Double) throws {
        guard sources.indices.contains(index) else { return }
        audio?.stop(); audio = try AVAudioPlayer(contentsOf: sources[index].url); partIndex = index
        audio?.currentTime = max(0, min(seconds-sources[index].start, audio?.duration ?? 0))
        position = sources[index].start + (audio?.currentTime ?? 0)
    }
    func toggle() {
        guard audio != nil else { return }
        if playing { audio?.pause(); playing = false; return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true); ownsSession = true
            if position >= duration - 0.1 { try selectPart(0, at: sources[0].start) }
            guard audio?.play() == true else { throw CaptureError("无法播放录音") }
            playing = true; timer?.cancel()
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                    guard let self, let audio = self.audio, self.playing else { return }
                    self.position = self.sources[self.partIndex].start + audio.currentTime
                    if !audio.isPlaying {
                        if audio.currentTime >= audio.duration-0.15 && self.partIndex+1 < self.sources.count {
                            do {
                                let next = self.partIndex+1
                                try self.selectPart(next, at: self.sources[next].start)
                                guard self.audio?.play() == true else { throw CaptureError("后续录音无法播放") }
                            } catch { self.error = error.localizedDescription; self.playing = false; return }
                        } else { self.playing = false; return }
                    }
                }
            }
        } catch { self.error = error.localizedDescription }
    }
    func seek(_ seconds: Double) {
        let target = max(0, min(seconds, duration))
        guard let i = sources.firstIndex(where: { target >= $0.start && target <= $0.start+$0.duration }) else {
            error = "这个时间段没有已保存的录音。"; return
        }
        let resume = playing
        do { try selectPart(i, at: target); if resume { playing = audio?.play() == true } }
        catch { self.error = error.localizedDescription; playing = false }
    }
    func stop() {
        timer?.cancel(); timer = nil; audio?.stop(); audio = nil; sources = []
        playing = false; position = 0; duration = 0
        if ownsSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            ownsSession = false
        }
    }
}

struct ClassReviewView: View {
    @Environment(\.scenePhase) private var scenePhase
    var library: ClassLibrary
    var allowAudio = true
    var onResume: ((ClassDocument) -> Void)?
    @State private var document: ClassDocument
    @State private var player = ClassAudioPlayer()
    @State private var translator = DeepSeekTranslation()
    @State private var notesGenerator = StudyNotes()
    @State private var tab = "字幕"
    @State private var query = ""
    @State private var mode = CaptionMode.bilingual
    @AppStorage(CaptionAppearance.storageKey) private var fontSize = CaptionAppearance.defaultSize
    @State private var error: String?
    @State private var sharing = false
    @State private var shareFiles: [URL] = []
    @State private var repairing = false
    @State private var repairTask: Task<Void, Never>?
    @State private var saveTask: Task<Void, Never>?
    @State private var importingAudio = false
    @State private var deleting = false
    @State private var handingOff = false
    @State private var editingLine: CaptionLine?
    @State private var editedFrench = ""
    init(library: ClassLibrary, initial: ClassDocument, allowAudio: Bool = true, onResume: ((ClassDocument) -> Void)? = nil) {
        self.library = library; self.allowAudio = allowAudio; self.onResume = onResume
        _document = State(initialValue: initial)
    }
    private var visibleLines: [CaptionLine] {
        document.displayLines.filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query)
            || ClassExport.chinese(for: $0, in: document).localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        VStack(spacing: 0) {
            reviewHeader
            if document.isResumable, allowAudio, onResume != nil {
                Button("继续这节课", systemImage: "mic.badge.plus") { continueClass() }
                    .buttonStyle(.borderedProminent).padding(.horizontal).disabled(repairing || notesGenerator.busy)
            }
            if allowAudio, library.audioURL(document) != nil { playbackBar }
            if let error { HStack { Text(error).foregroundStyle(.red); Button("重试保存") { save() } }.font(.caption).padding(.horizontal) }
            if let error = player.error { Text(error).font(.caption).foregroundStyle(.red) }
            Picker("内容", selection: $tab) {
                Text("字幕").tag("字幕"); Text("笔记").tag("笔记"); Text("重点 (\(document.bookmarks.count))").tag("重点")
            }.pickerStyle(.segmented).padding()
            if tab == "字幕" { transcriptView }
            else if tab == "笔记" { notesView }
            else { bookmarksView }
        }
        .background(ClairTheme.paper).foregroundStyle(ClairTheme.forest)
        .navigationTitle(document.title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { document.starred.toggle(); save() } label: { Image(systemName: document.starred ? "star.fill" : "star") }
                    .accessibilityLabel(document.starred ? "取消收藏" : "收藏")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("导出笔记、字幕与 JSON") { share(audio: false) }
                    Button("连同录音导出") { share(audio: true) }.disabled(library.audioURL(document) == nil)
                    if library.audioURL(document) == nil {
                        Button("关联原始录音") { importingAudio = true }.disabled(!allowAudio)
                    }
                    if document.deletedAt != nil {
                        Button("永久删除课堂与录音", role: .destructive) { deleting = true }
                    }
                } label: { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("导出课堂")
            }
        }
        .sheet(item: $editingLine) { line in
            NavigationStack {
                Form {
                    Section("修正原文（原始识别另行保留）") { TextEditor(text: $editedFrench).frame(minHeight: 200) }
                    Text("保存后仅补译这一段；若未配置翻译，可稍后点击补译。数学符号和变量请结合板书确认。")
                        .font(.caption).foregroundStyle(.secondary)
                }.navigationTitle("修正原文")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { editingLine = nil } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存并补译") {
                            do {
                                try document.correct(line.id, text: editedFrench); try library.save(document)
                                editingLine = nil; repair(only: [line.id])
                            } catch { self.error = error.localizedDescription }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $sharing) { ActivitySheet(items: shareFiles) }
        .fileImporter(isPresented: $importingAudio, allowedContentTypes: [.audio]) { result in
            do { try library.attachAudio(result.get(), to: &document); player.load(library.audioSources(document)) }
            catch { self.error = "关联录音失败：\(error.localizedDescription)" }
        }
        .confirmationDialog("永久删除课堂、笔记和录音？此操作无法恢复。", isPresented: $deleting, titleVisibility: .visible) {
            Button("永久删除", role: .destructive) {
                do { try library.permanentlyDelete(document.id) }
                catch { self.error = error.localizedDescription }
            }
        }
        .onAppear { if allowAudio { player.load(library.audioSources(document)) } }
        .onChange(of: allowAudio) { _, allowed in if allowed { player.load(library.audioSources(document)) } else { player.stop() } }
        .onChange(of: document.notes) { scheduleSave() }
        .onChange(of: document.title) { scheduleSave() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                player.stop(); notesGenerator.cancel(); repairTask?.cancel(); translator.cancel()
                if repairing { document.captions = translator.captions }
                saveTask?.cancel(); save()
            } else if phase == .active, allowAudio, player.duration == 0 { player.load(library.audioSources(document)) }
        }
        .onDisappear {
            player.stop(); notesGenerator.cancel(); repairTask?.cancel(); translator.cancel()
            if repairing { document.captions = translator.captions }
            saveTask?.cancel(); if !handingOff { save() }
        }
    }
    private var reviewHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("课堂标题", text: $document.title).font(.title2.bold()).onSubmit { save() }
            HStack {
                Text("\(document.course.name) · \(document.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(ClassExport.clock(document.duration))")
                Spacer()
                if repairing {
                    ProgressView()
                    Button("取消补译") { repairTask?.cancel(); translator.cancel() }
                } else if document.unfinishedCount > 0 {
                    Button("补译 \(document.unfinishedCount) 段") { repair() }.disabled(!allowAudio)
                }
            }.font(.caption).foregroundStyle(.secondary)
            if repairing { Text(translator.status).font(.caption) }
            if let message = document.lastError { Text(message).font(.caption).foregroundStyle(.orange) }
            if document.deletedAt != nil {
                Button("恢复这节课", systemImage: "arrow.uturn.backward") {
                    do { try library.setDeleted(document.id, deleted: false); document.deletedAt = nil }
                    catch { self.error = error.localizedDescription }
                }
            }
        }.padding()
    }
    private var playbackBar: some View {
        HStack {
            Button { player.toggle() } label: { Image(systemName: player.playing ? "pause.fill" : "play.fill") }.accessibilityLabel("播放或暂停录音")
            Text(ClassExport.clock(player.position)).monospacedDigit().font(.caption)
            Slider(value: Binding(get: { player.position }, set: { player.seek($0) }), in: 0...max(0.1, player.duration))
                .accessibilityLabel("录音位置")
            Text(ClassExport.clock(player.duration)).font(.caption)
        }.padding(.horizontal).padding(.bottom, 8)
    }
    private var transcriptView: some View {
        VStack {
            HStack {
                TextField("搜索本节课原文或译文", text: $query).textFieldStyle(.roundedBorder)
                Picker("语言", selection: $mode) { ForEach(CaptionMode.allCases, id: \.self) { Text($0.rawValue) } }
                    .pickerStyle(.segmented).frame(maxWidth: 190)
            }.padding(.horizontal)
            CaptionFontControl(size: $fontSize).padding(.horizontal)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(visibleLines) { line in
                        VStack(alignment: .leading, spacing: 8) {
                            let zh = ClassExport.chinese(for: line, in: document)
                            HStack {
                                Button(ClassExport.clock(line.start)) { player.seek(line.start) }
                                    .disabled(player.duration == 0).accessibilityLabel("跳到此处录音")
                                if !line.isFinal { Text("原文更新中").foregroundStyle(.secondary) }
                                if mode != .french { CaptionAmbiguityHint(chinese: zh, french: line.text) }
                                Spacer()
                                Button {
                                    document.bookmarks.append(ClassBookmark(seconds: line.start, text: String(line.text.prefix(80)))); save()
                                } label: { Image(systemName: "bookmark") }.accessibilityLabel("标记此段")
                            }.font(.caption)
                            if mode != .french {
                                Text(zh.isEmpty ? "〔缺少中文，可点击补译〕" : CaptionAmbiguity.displayText(zh)).font(.system(size: CaptionAppearance.normalized(fontSize))).foregroundStyle(ClairTheme.forest).textSelection(.enabled)
                            }
                            if mode != .chinese { Text(line.text).font(.system(size: CaptionAppearance.frenchSize(fontSize, bilingual: mode == .bilingual))).foregroundStyle(ClairTheme.secondary).textSelection(.enabled) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        .contextMenu {
                            Button("修正原文", systemImage: "pencil") { editedFrench = line.text; editingLine = line }
                                .disabled(!allowAudio || repairing || notesGenerator.busy)
                        }
                    }
                    if visibleLines.isEmpty { Text("没有匹配的字幕").foregroundStyle(.secondary) }
                }.padding(24)
            }
        }
    }
    private var notesView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("我的笔记").font(.headline)
                TextEditor(text: $document.notes).frame(minHeight: 220).padding(8)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                Divider()
                HStack {
                    Text("AI 课堂整理 · 待核对").font(.headline)
                    Spacer()
                    if notesGenerator.busy { Button("取消") { notesGenerator.cancel() } }
                    else {
                        Button(document.generatedNotes.isEmpty ? "整理本节课" : "重新整理") {
                            translator.refreshSettings()
                            notesGenerator.generate(document, model: translator.model) { text in document.generatedNotes = text; save() }
                        }.disabled(document.lines.isEmpty || repairing || !allowAudio)
                    }
                }
                Text("整理会将本节课法语原文发送给 DeepSeek，使用账户余额。笔记保留原文时间标记，不能替代原始记录。")
                    .font(.caption).foregroundStyle(.secondary)
                if !notesGenerator.progress.isEmpty { Text(notesGenerator.progress).font(.caption).foregroundStyle(.secondary) }
                if let error = notesGenerator.errorMessage { Text(error).foregroundStyle(.red) }
                Text(notesGenerator.busy ? notesGenerator.output : document.generatedNotes).textSelection(.enabled)
            }.padding(24)
        }
    }
    private var bookmarksView: some View {
        List {
            ForEach($document.bookmarks) { $mark in
                HStack {
                    Button(ClassExport.clock(mark.seconds)) { player.seek(mark.seconds) }.disabled(player.duration == 0)
                    TextField("重点备注", text: $mark.text, axis: .vertical).onChange(of: mark.text) { scheduleSave() }
                }
            }.onDelete { document.bookmarks.remove(atOffsets: $0); save() }
            if document.bookmarks.isEmpty { Text("听课时点“标记重点”，或在字幕旁点书签。") .foregroundStyle(.secondary) }
        }
    }
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { do { try await Task.sleep(for: .milliseconds(600)) } catch { return }; save() }
    }
    private func save() {
        guard !handingOff else { return }
        guard let latest = library.documents.first(where: { $0.id == document.id }) else { return }
        if ["preparing", "recording", "paused", "stopping"].contains(latest.status) { return }
        // A library action may move this record to Trash while its editor is closing.
        document.deletedAt = latest.deletedAt
        do { try library.save(document); error = nil }
        catch { self.error = "保存失败：\(error.localizedDescription)" }
    }
    private func share(audio: Bool) {
        guard library.documents.contains(where: { $0.id == document.id }) else { return }
        do { shareFiles = try library.exports(document, includeAudio: audio); sharing = true }
        catch { self.error = "导出失败：\(error.localizedDescription)" }
    }
    private func continueClass() {
        guard !repairing, !notesGenerator.busy, document.isResumable,
              library.documents.first(where: { $0.id == document.id })?.isResumable == true else { return }
        do {
            saveTask?.cancel(); try library.save(document)
            player.stop(); translator.cancel(); notesGenerator.cancel(); handingOff = true
            onResume?(document)
        } catch { self.error = "继续前保存失败：\(error.localizedDescription)" }
    }
    private func repair(only: Set<UUID>? = nil) {
        guard !repairing, !notesGenerator.busy else { return }
        translator.refreshSettings()
        guard DeepSeekKeychain.read() != nil else { error = "请先在设置中保存 DeepSeek 密钥"; return }
        guard translator.enabled else { error = "请先在设置中打开中文字幕"; return }
        repairing = true; translator.restore(document, only: only)
        repairTask = Task {
            // Long backlogs can be continued with another explicit tap; no unbounded background spend.
            await translator.finish(timeout: 180)
            document.captions = translator.captions; repairing = false; save()
        }
    }
}

struct ActivitySheet: UIViewControllerRepresentable {
    var items: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
