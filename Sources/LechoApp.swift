import SwiftUI
import UniformTypeIdentifiers
import UIKit

@main @MainActor
struct LechoApp: App {
    @State private var library: ClassLibrary
    @State private var classroom: ClassroomController
    @Environment(\.scenePhase) private var scenePhase
    init() {
        let store = ClassLibrary()
        _library = State(initialValue: store)
        _classroom = State(initialValue: ClassroomController(library: store))
    }
    var body: some Scene {
        WindowGroup {
            LibraryView(library: library, classroom: classroom)
                .tint(ClairTheme.forest).preferredColorScheme(.light)
                .background(ClairTheme.canvas)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { classroom.applicationDidEnterBackground() }
                    else if phase == .active { classroom.applicationDidBecomeActive() }
                }
        }
    }
}

struct LibraryView: View {
    @Bindable var library: ClassLibrary
    @Bindable var classroom: ClassroomController
    @State private var selection: UUID?
    @State private var query = ""
    @State private var showNew = false
    @State private var showSettings = false
    @State private var showTrash = false
    @State private var importRecord = false
    @State private var pendingPermanentDelete: ClassDocument?
    private var results: [ClassDocument] {
        library.documents.filter { doc in
            (showTrash ? doc.deletedAt != nil : doc.deletedAt == nil)
                && (query.isEmpty || doc.searchableText.localizedCaseInsensitiveContains(query))
        }
    }
    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    SidebarWordmark().padding(.vertical, 14)
                }.listRowBackground(Color.clear)
                if let error = library.errorMessage {
                    Section { Text(error).font(.caption).foregroundStyle(.red) }
                }
                Section {
                    Button { showNew = true } label: { Label("开始新课", systemImage: "plus.circle.fill") }
                        .buttonStyle(PaperClassButtonStyle())
                        .disabled(classroom.busy || showTrash)
                    if classroom.busy, let doc = classroom.document {
                        Button { selection = doc.id } label: { Label("返回正在听的课", systemImage: "waveform") }
                    }
                }.listRowBackground(Color.clear)
                Section(showTrash ? "最近删除（可恢复）" : "我的课堂") {
                    ForEach(results) { doc in
                        NavigationLink(value: doc.id) { LibraryRow(document: doc, active: classroom.busy && doc.id == classroom.document?.id) }
                            .listRowBackground(Color.white.opacity(selection == doc.id ? 0.12 : 0))
                            .swipeActions(edge: .leading, allowsFullSwipe: false) { deletionActions(doc) }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) { deletionActions(doc) }
                            .contextMenu { deletionActions(doc) }
                    }
                    if results.isEmpty { Text(query.isEmpty ? "还没有课堂记录" : "没有匹配的课堂").foregroundStyle(.secondary) }
                }
            }
            .scrollContentBackground(.hidden).background(ClairTheme.forest)
            .foregroundStyle(ClairTheme.paper).tint(ClairTheme.paper)
            .searchable(text: $query, prompt: "搜索标题、法语或中文")
            .navigationTitle("我的课堂")
            .toolbarBackground(ClairTheme.forest, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("设置")
                        .disabled(classroom.busy)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("导入记录", systemImage: "square.and.arrow.down") { importRecord = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showTrash.toggle(); selection = nil } label: { Image(systemName: showTrash ? "books.vertical" : "trash") }
                        .accessibilityLabel(showTrash ? "返回课堂库" : "最近删除")
                }
            }
        } detail: {
            if let selection, classroom.document?.id == selection, classroom.busy {
                LiveClassView(classroom: classroom)
            } else if let selection, let doc = library.documents.first(where: { $0.id == selection }) {
                ClassReviewView(library: library, initial: doc, allowAudio: !classroom.busy) { saved in
                    Task { await classroom.resume(saved) }
                }.id(doc.id)
            } else {
                ContentUnavailableView {
                    Label("听懂课堂，留下原文", systemImage: "captions.bubble")
                } description: {
                    Text("本地识别法语，DeepSeek 实时翻译。\n课程、字幕、笔记与录音保存在此 iPad。")
                } actions: {
                    Button("开始新课") { showNew = true }.buttonStyle(PaperClassButtonStyle()).disabled(classroom.busy)
                    if !classroom.translator.hasKey {
                        Button("设置 DeepSeek 密钥") { showSettings = true }.disabled(classroom.busy)
                    }
                }
            }
        }
        .background(ClairTheme.canvas)
        .confirmationDialog("永久删除这节课？", isPresented: Binding(
            get: { pendingPermanentDelete != nil }, set: { if !$0 { pendingPermanentDelete = nil } }),
            titleVisibility: .visible, presenting: pendingPermanentDelete) { doc in
            Button("永久删除", role: .destructive) {
                guard !classroom.busy || classroom.document?.id != doc.id else { return }
                do {
                    try library.permanentlyDelete(doc.id)
                    if selection == doc.id { selection = nil }
                } catch { library.errorMessage = error.localizedDescription }
                pendingPermanentDelete = nil
            }
            Button("取消", role: .cancel) { pendingPermanentDelete = nil }
        } message: { doc in Text("“\(doc.title)”的字幕、笔记与录音将永久删除，无法恢复。") }
        .onChange(of: classroom.busy) { _, busy in
            if !busy && classroom.document?.status == "suspended" { selection = nil }
        }
        .onChange(of: classroom.document?.id) { _, id in selection = id }
        .sheet(isPresented: $showNew) {
            NewClassView(courses: library.courses, hasTranslation: classroom.translator.hasKey && classroom.translator.enabled) { title, course, audio, file in
                Task { await classroom.start(title: title, course: course, saveAudio: audio, fileURL: file) }
            }
            .tint(ClairTheme.forest).preferredColorScheme(.light)
        }
        .sheet(isPresented: $showSettings) { AppSettingsView(translator: classroom.translator, library: library) }
        .fileImporter(isPresented: $importRecord, allowedContentTypes: [.json]) { result in
            do { selection = try library.importRecord(result.get()) }
            catch { library.errorMessage = "导入失败：\(error.localizedDescription)" }
        }
    }
    @ViewBuilder private func deletionActions(_ doc: ClassDocument) -> some View {
        if !classroom.busy || doc.id != classroom.document?.id {
            if showTrash {
                Button("永久删除", systemImage: "trash.slash", role: .destructive) { pendingPermanentDelete = doc }
                Button("恢复", systemImage: "arrow.uturn.backward") { setDeleted(doc, deleted: false) }.tint(.green)
            } else {
                Button("删除", systemImage: "trash", role: .destructive) { setDeleted(doc, deleted: true) }
            }
        }
    }
    private func setDeleted(_ doc: ClassDocument, deleted: Bool) {
        guard !classroom.busy || doc.id != classroom.document?.id else { return }
        do { try library.setDeleted(doc.id, deleted: deleted); if selection == doc.id { selection = nil } }
        catch { library.errorMessage = error.localizedDescription }
    }
}

struct SidebarWordmark: View {
    private var lettering: Font {
        if UIFont(name: "SnellRoundhand-Bold", size: 39) != nil {
            return .custom("SnellRoundhand-Bold", size: 39, relativeTo: .largeTitle)
        }
        return .system(size: 35, weight: .regular, design: .serif).italic()
    }
    var body: some View {
        HStack(spacing: 10) {
            Image("LechoFeather").resizable().scaledToFit().frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 10)).accessibilityHidden(true)
            Text("L'écho").font(lettering).lineLimit(1).minimumScaleFactor(0.7)
                .foregroundStyle(ClairTheme.paper)
        }.accessibilityElement(children: .ignore).accessibilityLabel("L'écho，法语课堂")
    }
}

/// Explicit colors prevent sidebar tint from turning the collapsed-view button white.
struct PaperClassButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline).padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 46)
            .foregroundStyle(ClairTheme.paper).tint(ClairTheme.paper)
            .background(ClairTheme.forest.opacity(configuration.isPressed ? 0.82 : 1), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ClairTheme.paper.opacity(0.25), lineWidth: 1))
            .opacity(enabled ? 1 : 0.45)
    }
}

struct LibraryRow: View {
    var document: ClassDocument
    var active: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                if active { Image(systemName: "waveform").foregroundStyle(.red) }
                if document.starred { Image(systemName: "star.fill").foregroundStyle(.orange) }
                Text(document.title).font(.headline).lineLimit(2)
            }
            Text("\(document.course.name) · \(document.startedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
            Text("\(ClassExport.clock(document.duration))\(document.status == "suspended" ? " · 已暂停，可继续" : (document.status == "interrupted" ? " · 中断后可继续" : ""))")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 5)
    }
}

struct NewClassView: View {
    var courses: [Course]
    var hasTranslation: Bool
    var onStart: (String, Course, Bool, URL?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var selected: UUID?
    @State private var saveAudio = true
    @State private var importAudio = false
    @State private var error: String?
    private var course: Course { courses.first { $0.id == selected } ?? courses.first ?? Course.defaults[0] }
    var body: some View {
        NavigationStack {
            Form {
                Section("这节课") {
                    TextField("课程标题（可留空）", text: $title)
                    Picker("课程与术语", selection: $selected) {
                        ForEach(courses) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Text(course.subject).font(.caption).foregroundStyle(.secondary)
                }.listRowBackground(ClairTheme.paper)
                Section {
                    Toggle("保存录音，供课后回听", isOn: $saveAudio)
                    Text("录音留在 iPad；法语片段、前文和本课程术语会发送给 DeepSeek。首次使用会下载 Apple 法语识别资源。")
                        .font(.caption).foregroundStyle(.secondary)
                    if !hasTranslation { Text("尚未启用 DeepSeek，本次只转写法语。可先关闭此窗口，在设置中保存密钥。").foregroundStyle(.orange) }
                }.listRowBackground(ClairTheme.paper)
                Section {
                    Button("开始现场听课", systemImage: "mic.fill") { start(nil) }.buttonStyle(PaperClassButtonStyle())
                    Button("导入音频转写", systemImage: "doc.badge.plus") { importAudio = true }
                    Text("导入 CAF、WAV、M4A 等音频，按原速处理；切后台会暂停，回到本 App 后手动继续。录屏请先导出为音频。")
                        .font(.caption).foregroundStyle(.secondary)
                }.listRowBackground(ClairTheme.paper)
                if let error { Text(error).foregroundStyle(.red) }
            }
            .scrollContentBackground(.hidden).background(ClairTheme.canvas)
            .navigationTitle("开始新课")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .onAppear { if selected == nil { selected = courses.first?.id } }
            .fileImporter(isPresented: $importAudio, allowedContentTypes: [.audio]) { result in
                switch result {
                case .success(let url): start(url)
                case .failure(let e): error = e.localizedDescription
                }
            }
        }.tint(ClairTheme.forest).preferredColorScheme(.light)
    }
    private func start(_ url: URL?) { onStart(title, course, saveAudio, url); dismiss() }
}

enum CaptionMode: String, CaseIterable { case bilingual = "法中", french = "法语", chinese = "中文" }

struct LiveClassView: View {
    @Bindable var classroom: ClassroomController
    @State private var follow = true
    @State private var mode = CaptionMode.bilingual
    @AppStorage(CaptionAppearance.storageKey) private var fontSize = CaptionAppearance.defaultSize
    @State private var showNotes = false
    @State private var ending = false
    private var chineseLength: Int { classroom.translator.captions.reduce(0) { $0 + $1.chinese.count } }
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        if mode == .french || !classroom.translator.enabled || !classroom.translator.hasKey {
                            ForEach(classroom.displayLines) { line in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(ClassExport.clock(line.start) + (line.isFinal ? "" : " · 识别中"))
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(line.text).font(.system(size: CaptionAppearance.normalized(fontSize))).textSelection(.enabled)
                                }
                            }
                        } else {
                            ForEach(classroom.translator.captions) { row in
                                CaptionCard(caption: row, size: fontSize, mode: mode)
                                Rectangle().fill(ClairTheme.rule).frame(height: 1)
                            }
                        }
                        if classroom.lines.isEmpty {
                            ContentUnavailableView("等待法语声音", systemImage: "waveform", description: Text(classroom.status))
                        }
                        Color.clear.frame(height: 2).id("latest")
                    }.padding(.horizontal, 30).padding(.vertical, 12).frame(maxWidth: 1100, alignment: .leading)
                        .frame(maxWidth: .infinity)
                }
                .background(ClairTheme.paper)
                .onScrollPhaseChange { _, phase in if phase == .interacting { follow = false } }
                .onChange(of: classroom.eventCount) { if follow { proxy.scrollTo("latest", anchor: .bottom) } }
                .onChange(of: chineseLength) { if follow { proxy.scrollTo("latest", anchor: .bottom) } }
                .onChange(of: follow) { if follow { proxy.scrollTo("latest", anchor: .bottom) } }
            }
            Divider()
            ViewThatFits(in: .horizontal) {
                controls
                controls.labelStyle(.iconOnly).labelsHidden()
                compactControls
            }.padding().buttonStyle(.bordered)
        }
        .background(ClairTheme.canvas).foregroundStyle(ClairTheme.forest)
        .navigationTitle(classroom.document?.title ?? "听课")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("结束并保存本节课？", isPresented: $ending, titleVisibility: .visible) {
            Button("结束并保存") { Task { await classroom.stop() } }
        }
        .sheet(isPresented: $showNotes, onDismiss: { classroom.saveNow() }) {
            NavigationStack {
                TextEditor(text: Binding(get: { classroom.document?.notes ?? "" }, set: { classroom.updateNotes($0) }))
                    .padding().navigationTitle("随手笔记")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { classroom.saveNow(); showNotes = false } } }
            }
        }
    }
    private var controls: some View {
        HStack(spacing: 14) {
            Button { classroom.togglePause() } label: {
                Label(classroom.state == .paused ? "继续" : "暂停", systemImage: classroom.state == .paused ? "play.fill" : "pause.fill")
            }.disabled(!classroom.canPause)
            Button("标记重点", systemImage: "bookmark") { classroom.bookmark() }.disabled(!classroom.canPause)
            Button("随手笔记", systemImage: "square.and.pencil") { showNotes = true }
            if classroom.state == .paused {
                Button("保存退出", systemImage: "rectangle.portrait.and.arrow.right") { Task { await classroom.suspendAndExit() } }
            }
            Spacer(minLength: 0)
            Toggle("跟随", isOn: $follow).fixedSize().accessibilityLabel("自动跟随最新字幕")
            Button("结束", systemImage: "stop.circle", role: .destructive) { ending = true }
                .disabled(classroom.state == .stopping)
        }
    }
    private var compactControls: some View {
        VStack(spacing: 8) {
            HStack {
                Button(classroom.state == .paused ? "继续" : "暂停", systemImage: classroom.state == .paused ? "play.fill" : "pause.fill") { classroom.togglePause() }.disabled(!classroom.canPause)
                Button("重点", systemImage: "bookmark") { classroom.bookmark() }.disabled(!classroom.canPause)
                Button("笔记", systemImage: "square.and.pencil") { showNotes = true }
            }
            HStack {
                Toggle("跟随", isOn: $follow).fixedSize()
                if classroom.state == .paused { Button("保存退出") { Task { await classroom.suspendAndExit() } } }
                Button("结束", role: .destructive) { ending = true }.disabled(classroom.state == .stopping)
            }
        }
    }
    private var captionModePicker: some View {
        Picker("显示", selection: $mode) { ForEach(CaptionMode.allCases, id: \.self) { Text($0.rawValue) } }
            .pickerStyle(.segmented).frame(maxWidth: 200)
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(classroom.state == .recording ? .red : .orange).frame(width: 9, height: 9)
                Text(classroom.status).font(.headline)
                Text(ClassExport.clock(classroom.audioSeconds)).monospacedDigit()
                Spacer()
                ProgressView(value: Double(classroom.meter)).frame(width: 70).accessibilityLabel("输入音量")
            }
            ViewThatFits(in: .horizontal) {
                HStack { captionModePicker; CaptionFontControl(size: $fontSize) }
                VStack(alignment: .leading, spacing: 8) { captionModePicker; CaptionFontControl(size: $fontSize) }
            }
            Text(classroom.translator.status).font(.caption).foregroundStyle(.secondary)
            Text(classroom.translator.reviewStatus).font(.caption2).foregroundStyle(ClairTheme.secondary)
            if let error = classroom.errorMessage {
                HStack { Text(error).font(.caption).foregroundStyle(.red); Button("重试保存") { classroom.saveNow() } }
            }
            if classroom.translator.canRetry {
                HStack {
                    Text(classroom.translator.attempts.last(where: { $0.status == "failed" })?.error ?? "中文连接未完成")
                        .font(.caption).foregroundStyle(.orange)
                    Button("重试翻译") { classroom.translator.retryFailed() }
                }
            }
        }.padding().background(ClairTheme.canvas)
    }
}

struct CaptionCard: View {
    var caption: ChineseCaption
    var size: Double = 24
    var mode = CaptionMode.bilingual
    private var stale: Bool { caption.translatedFrench != caption.french && !caption.chinese.isEmpty }
    private var label: String {
        if stale { return "原文已改 · 中文待更新" }
        switch caption.status {
        case "complete": return caption.sourceFinal ? "" : "暂译"
        case "streaming": return "翻译中"
        case "failed": return "翻译失败 · 可补译"
        case "cancelled": return "翻译未完成"
        default: return "等待中文"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(ClassExport.clock(caption.audioStart))
                if !label.isEmpty { Text(label) }
                if mode != .french { CaptionAmbiguityHint(chinese: caption.chinese, french: caption.french) }
            }.font(.caption).foregroundStyle(.secondary)
            if mode != .french {
                Text(caption.chinese.isEmpty ? "等待中文…" : CaptionAmbiguity.displayText(caption.chinese))
                    .font(.system(size: CaptionAppearance.normalized(size))).foregroundStyle(stale ? .secondary : .primary).textSelection(.enabled)
            }
            if mode != .chinese {
                Text(caption.french).font(.system(size: CaptionAppearance.frenchSize(size, bilingual: mode == .bilingual)))
                    .foregroundStyle(.secondary).textSelection(.enabled)
            }
        }.padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
    }
}
