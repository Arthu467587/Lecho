import Foundation

struct Course: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var subject: String
    var glossary: String
    static let defaults = [
        Course(name: "数学", subject: "数学：分析、代数、概率；根据当前语境区分术语", glossary: "convergence simple = 逐点收敛；convergence uniforme = 一致收敛；si et seulement si = 当且仅当；condition nécessaire = 必要条件；condition suffisante = 充分条件；presque partout = 几乎处处；corps（代数）= 域；anneau = 环；application = 映射；borne supérieure = 上确界；suite = 数列；série = 级数"),
        Course(name: "物理", subject: "物理：力学、电磁学、热学；保留变量和单位", glossary: "travail = 功；puissance = 功率；quantité de mouvement = 动量；moment cinétique = 角动量；référentiel = 参考系；champ = 场；tension（电学）= 电压；tension（绳索）= 张力；corps（力学）= 物体；masse constante = 恒定质量"),
        Course(name: "其他课程", subject: "法语课堂", glossary: "")
    ]
}

struct ClassBookmark: Identifiable, Codable {
    var id = UUID()
    var seconds: Double
    var text: String
}

struct ClassDocument: Identifiable, Codable {
    var schemaVersion = 1
    var id = UUID()
    var title: String
    var course: Course
    var startedAt = Date()
    var endedAt: Date?
    var status = "recording"
    var source = "microphone"
    var duration = 0.0
    var audioFilename: String?
    var lines: [CaptionLine] = []
    var captions: [ChineseCaption] = []
    var bookmarks: [ClassBookmark] = []
    var notes = ""
    var generatedNotes = ""
    var starred = false
    var deletedAt: Date?
    var lastError: String?
    var model = "deepseek-flash"
    var semanticUnits: [SemanticUnit]?
    var correctedText: [String: String]?
    var audioParts: [ClassAudioPart]?
    var recordingEnabled: Bool?

    var displayLines: [CaptionLine] {
        (semanticUnits?.map(\.line) ?? lines).map { original in
            var line = original
            if let correction = correctedText?[line.id.uuidString] { line.text = correction; line.isFinal = true }
            return line
        }
    }
    var translationSlices: [TranslationSlice] {
        guard let units = semanticUnits else { return TranslationChunks.legacySlices(displayLines) }
        return units.map { unit in
            var slice = unit.slice
            if let correction = correctedText?[unit.id.uuidString] { slice.french = correction; slice.isFinal = true }
            return slice
        }
    }
    mutating func correct(_ id: UUID, text: String) throws {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 6_000, displayLines.contains(where: { $0.id == id }) else {
            throw CaptureError("请输入1至6000字符的修正原文。")
        }
        if correctedText == nil { correctedText = [:] }
        correctedText?[id.uuidString] = value
        for i in captions.indices where captions[i].id.hasPrefix(id.uuidString + ":") { captions[i].status = "stale" }
    }

    var unfinishedCount: Int {
        let slices = translationSlices
        let saved = Dictionary(captions.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        return slices.filter { slice in
            guard let c = saved[slice.id] else { return true }
            return c.status != "complete" || c.translatedFrench != slice.french
        }.count
    }
    var searchableText: String {
        ([title, course.name, notes, generatedNotes] + displayLines.map(\.text) + lines.map(\.text) + captions.map(\.chinese)).joined(separator: "\n")
    }
}

enum ClassExport {
    static func clock(_ seconds: Double) -> String {
        let n = max(0, Int(seconds.isFinite ? seconds : 0))
        return n >= 3600 ? String(format: "%d:%02d:%02d", n / 3600, n / 60 % 60, n % 60)
            : String(format: "%02d:%02d", n / 60, n % 60)
    }
    static func stamp(_ seconds: Double) -> String {
        let n = max(0, Int((seconds.isFinite ? seconds : 0) * 1000))
        return String(format: "%02d:%02d:%02d,%03d", n / 3_600_000, n / 60_000 % 60, n / 1000 % 60, n % 1000)
    }
    static func chinese(for line: CaptionLine, in doc: ClassDocument) -> String {
        let prefix = line.id.uuidString + ":"
        return doc.captions.filter { $0.id.hasPrefix(prefix) }.map { c in
            let uncertain = c.status != "complete" || c.translatedFrench != c.french
            return (uncertain ? "〔未完成/待更新〕" : "") + (c.chinese.isEmpty ? "〔缺少中文〕" : c.chinese)
        }.joined(separator: " ")
    }
    static func markdown(_ doc: ClassDocument) -> String {
        var text = "# \(doc.title)\n\n课程：\(doc.course.name) · \(doc.startedAt.formatted()) · \(clock(doc.duration))\n\n"
        text += "> 法语为本地语音识别结果；中文及 AI 笔记可能有误。时间戳对应识别段落，未按单词精确对齐。\n\n"
        if !doc.notes.isEmpty { text += "## 我的笔记\n\n\(doc.notes)\n\n" }
        if !doc.bookmarks.isEmpty {
            text += "## 课堂重点\n\n" + doc.bookmarks.map { "- [\(clock($0.seconds))] \($0.text)" }.joined(separator: "\n") + "\n\n"
        }
        if !doc.generatedNotes.isEmpty { text += "## AI 整理（待核对）\n\n\(doc.generatedNotes)\n\n" }
        text += "## 法中原文\n\n"
        for line in doc.displayLines {
            text += "### \(clock(line.start))\(line.isFinal ? "" : " · 识别未确认")\n\n\(line.text)\n\n"
            let zh = chinese(for: line, in: doc)
            text += (zh.isEmpty ? "〔缺少中文〕" : zh) + "\n\n"
        }
        if doc.semanticUnits != nil || doc.correctedText != nil {
            text += "## 原始识别（保留）\n\n" + doc.lines.map { "[\(clock($0.start))] \($0.text)" }.joined(separator: "\n\n") + "\n"
        }
        return text
    }
    static func srt(_ doc: ClassDocument) -> String {
        // Fragments from one recognition range have coarse shared timing. Coalesce overlaps;
        // never fabricate word timing or emit overlapping cues that hide each other in players.
        var cues: [(start: Double, end: Double, french: String, chinese: String)] = []
        for line in doc.displayLines {
            let zh = chinese(for: line, in: doc)
            let chineseText = zh.isEmpty ? "〔缺少中文〕" : zh
            if let last = cues.last, line.start < last.end - 0.001 {
                let i = cues.count-1
                cues[i].end = max(last.end, line.end)
                cues[i].french += " " + line.text; cues[i].chinese += " " + chineseText
            } else { cues.append((line.start, max(line.start+0.1, line.end), line.text, chineseText)) }
        }
        return cues.enumerated().map { i, cue in
            "\(i+1)\n\(stamp(cue.start)) --> \(stamp(cue.end))\n\(cue.french)\n\(cue.chinese)\n"
        }.joined(separator: "\n")
    }
    static func validatedAudioName(_ name: String?) -> String? {
        guard let name, !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\\"), !name.contains(":"),
              !name.contains("\0") else { return nil }
        return name
    }
}
