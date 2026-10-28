import SwiftUI

struct AppSettingsView: View {
    @Bindable var translator: DeepSeekTranslation
    @Bindable var library: ClassLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var enabled = true
    @State private var model = "deepseek-flash"
    @State private var enhancedSegmentation = true
    @AppStorage(CaptionAppearance.storageKey) private var fontSize = CaptionAppearance.defaultSize
    @AppStorage(CaptionAmbiguity.visibilityKey) private var showAmbiguityHints = true
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("DeepSeek") {
                    Toggle("实时中文字幕", isOn: $enabled)
                    SecureField(translator.hasKey ? "已保存密钥；粘贴可替换" : "粘贴 DeepSeek API 密钥", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text(translator.hasKey ? "此 iPad 钥匙串中已有密钥" : "尚未保存密钥").font(.caption).foregroundStyle(.secondary)
                    TextField("模型名称", text: $model).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("默认 deepseek-flash，关闭思考并流式显示。只连接 DeepSeek 官方接口。API 使用会消耗你的账户余额。")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("增强断句（DeepSeek）", isOn: $enhancedSegmentation)
                    Text("逗号片段先翻译，已显示中文后再结合后文合并；审查只在空闲进行，合并时保留旧中文。会增加文本请求及可能的补译费用；关闭或不可用时仍使用本地滚动断句。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("字幕显示") {
                    CaptionFontControl(size: $fontSize)
                    Text("现场听课与课堂回看共用字号，重启保留；默认21点，可选17、21、26、32点。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("La dérivée de la position donne la vitesse.\n位置的导数给出速度。")
                        .font(.system(size: CaptionAppearance.normalized(fontSize)))
                    Toggle("显示歧义提示", isOn: $showAmbiguityHints)
                    Text("仅在译文被标记为存疑时显示小型提示，点击查看说明；关闭后仍保留原始译文与导出中的存疑标记。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("我的课程") {
                    NavigationLink("编辑课程与法中术语") { CourseListView(library: library) }
                    Text("每次开课固定使用所选课程的术语；课后修改不会改写原始课堂记录。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("使用与数据") {
                    Text("法语语音在本机识别；录音不会发送给 DeepSeek。翻译会发送当前法语、邻近前文和课程术语；课后整理会发送本节课的法语原文。")
                    Text("字幕中的时间对应识别段落。暂译会修订，数学与物理中的否定、条件、符号及单位请保留原文对照。")
                    Text("现场听课开始后，切换 App 或锁屏会继续收音、识别和翻译；暂停不会自动恢复。来电、系统抢麦或强制退出仍可能中断。导入文件切后台会暂停，返回后手动继续。")
                    Text("课堂数据可从“文件 → 我的 iPad → L'écho → ClairLibrary”备份。卸载应用会移除课堂数据，请先导出。")
                }.font(.callout).foregroundStyle(.secondary)
                Section {
                    Button("移除此 iPad 保存的密钥", role: .destructive) { translator.removeKey(); key = "" }
                    Text("L'écho 1.3.0 · iPadOS 26 及以上 · 法语 → 简体中文").font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .scrollContentBackground(.hidden).background(ClairTheme.canvas)
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { key = ""; dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        do {
                            translator.enabled = enabled; translator.model = model
                            translator.reviewEnabled = enhancedSegmentation
                            try translator.saveSettings(key: key); key = ""; dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }
            }
            .onAppear { enabled = translator.enabled; model = translator.model; enhancedSegmentation = translator.reviewEnabled }
        }
    }
}

struct CourseListView: View {
    @Bindable var library: ClassLibrary
    @State private var adding = false
    var body: some View {
        List {
            ForEach(library.courses) { course in
                NavigationLink {
                    CourseEditor(course: course, library: library)
                } label: { VStack(alignment: .leading) { Text(course.name); Text(course.subject).font(.caption).foregroundStyle(.secondary) } }
            }
        }.navigationTitle("课程与术语")
            .toolbar { Button("新建课程", systemImage: "plus") { adding = true } }
            .sheet(isPresented: $adding) {
                NavigationStack { CourseEditor(course: Course(name: "新课程", subject: "", glossary: ""), library: library) }
            }
    }
}

struct CourseEditor: View {
    @State var course: Course
    var library: ClassLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    var body: some View {
        Form {
            TextField("课程名称", text: $course.name)
            TextField("学科与课程主题", text: $course.subject, axis: .vertical)
            Section("法中术语与易混概念") {
                TextEditor(text: $course.glossary).frame(minHeight: 260)
                Text("例如 convergence uniforme = 一致收敛。按具体学科限定歧义词，避免把代数中的 corps 翻译成物体。最多保存 12,000 字符。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("编辑课程")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard !course.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "请填写课程名称"; return }
                        guard course.glossary.count <= 12_000 else { error = "术语表过长，请缩减到 12,000 字符以内"; return }
                        let previous = library.courses
                        if let i = library.courses.firstIndex(where: { $0.id == course.id }) { library.courses[i] = course }
                        else { library.courses.append(course) }
                        do { try library.saveCourses(); dismiss() }
                        catch { library.courses = previous; self.error = error.localizedDescription }
                    }
                }
            }
    }
}
