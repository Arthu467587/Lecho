import Foundation
import Observation

@MainActor @Observable
final class ClassLibrary {
    var documents: [ClassDocument] = []
    var courses: [Course] = []
    var errorMessage: String?
    @ObservationIgnored let root: URL
    init() {
        root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClairLibrary", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let courseURL = root.appendingPathComponent("courses.json")
            if FileManager.default.fileExists(atPath: courseURL.path) {
                courses = try Self.decoder().decode([Course].self, from: Data(contentsOf: courseURL))
            } else { courses = Course.defaults; try saveCourses() }
        } catch { courses = Course.defaults; errorMessage = "课程配置读取失败：\(error.localizedDescription)" }
        reload()
    }
    static func decoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }
    func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func reload() {
        do {
            let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            var loaded: [ClassDocument] = []
            for folder in folders where UUID(uuidString: folder.lastPathComponent) != nil {
                do {
                    var doc = try Self.decoder().decode(ClassDocument.self, from: Data(contentsOf: folder.appendingPathComponent("class.json")))
                    guard doc.schemaVersion == 1, doc.id.uuidString == folder.lastPathComponent,
                          Self.validDerivedData(doc) else { throw CaptureError("记录格式或目录不匹配") }
                    if ["recording", "paused", "preparing", "stopping"].contains(doc.status) {
                        doc.status = "interrupted"; doc.lastError = "上次听课未正常结束，已恢复最近自动保存的内容。"
                        try Self.encoder().encode(doc).write(to: folder.appendingPathComponent("class.json"), options: Self.libraryWriteOptions)
                    }
                    loaded.append(doc)
                } catch { errorMessage = "有课堂记录无法读取，原文件已保留：\(folder.lastPathComponent)" }
            }
            documents = loaded.sorted { $0.startedAt > $1.startedAt }
        } catch { errorMessage = "课堂库读取失败：\(error.localizedDescription)" }
    }
    private static var libraryWriteOptions: Data.WritingOptions {
        #if os(iOS)
        return [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        return [.atomic]
        #endif
    }
    func saveCourses() throws {
        try Self.encoder().encode(courses).write(to: root.appendingPathComponent("courses.json"), options: Self.libraryWriteOptions)
    }
    func save(_ doc: ClassDocument) throws {
        guard Self.validDerivedData(doc) else { throw CaptureError("课堂派生分段或录音时间无效，原文件未覆盖。") }
        let directory = folder(doc.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder().encode(doc).write(to: directory.appendingPathComponent("class.json"), options: Self.libraryWriteOptions)
        if let index = documents.firstIndex(where: { $0.id == doc.id }) { documents[index] = doc }
        else { documents.insert(doc, at: 0) }
    }
    func audioURL(_ doc: ClassDocument) -> URL? {
        audioSources(doc).first?.url
    }
    func audioSources(_ doc: ClassDocument) -> [ClassAudioSource] {
        if let parts = doc.audioParts, !parts.isEmpty {
            return parts.sorted { $0.start < $1.start }.compactMap { part in
                guard let name = ClassExport.validatedAudioName(part.filename), part.duration > 0 else { return nil }
                let url = folder(doc.id).appendingPathComponent(name)
                return FileManager.default.fileExists(atPath: url.path) ? ClassAudioSource(url: url, start: part.start, duration: part.duration) : nil
            }
        }
        guard let name = ClassExport.validatedAudioName(doc.audioFilename) else { return [] }
        let url = folder(doc.id).appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? [ClassAudioSource(url: url, start: 0, duration: doc.duration)] : []
    }
    private static func validDerivedData(_ doc: ClassDocument) -> Bool {
        guard ClassContinuation.validParts(doc.audioParts ?? []),
              (doc.correctedText ?? [:]).allSatisfy({ UUID(uuidString: $0.key) != nil && !$0.value.isEmpty && $0.value.count <= 6_000 }) else { return false }
        guard let units = doc.semanticUnits else { return true }
        let sources = Set(doc.lines.map(\.id))
        guard units.count <= 100_000, units.allSatisfy({ !$0.fragments.isEmpty && $0.fragments.count <= 1_000 }) else { return false }
        return Set(units.map(\.id)).count == units.count && units.allSatisfy { unit in
            unit.fragments.allSatisfy { sources.contains($0.sourceID) && $0.start.isFinite && $0.end.isFinite &&
                $0.start >= 0 && $0.end >= $0.start && $0.end <= 604_800 && !$0.text.isEmpty }
        }
    }
    func setDeleted(_ id: UUID, deleted: Bool) throws {
        guard var doc = documents.first(where: { $0.id == id }) else { return }
        doc.deletedAt = deleted ? Date() : nil; try save(doc)
    }
    func permanentlyDelete(_ id: UUID) throws {
        guard let doc = documents.first(where: { $0.id == id }), doc.deletedAt != nil else { return }
        try FileManager.default.removeItem(at: folder(id))
        documents.removeAll { $0.id == id }
    }
    func importRecord(_ url: URL) throws -> UUID {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 25_000_000 else { throw CaptureError("记录超过 25 MB，请从文件 App 直接恢复备份文件夹") }
        let data = try Data(contentsOf: url)
        let decoder = Self.decoder()
        var doc: ClassDocument
        if let current = try? decoder.decode(ClassDocument.self, from: data) {
            guard current.schemaVersion == 1 else { throw CaptureError("不支持这个课堂记录版本") }
            doc = current
        } else {
            // Previous local-test reports can be kept as readable classroom history.
            struct Legacy: Decodable {
                var sampleName: String; var createdAt: Date; var durationSeconds: Double
                var lines: [CaptionLine]; var chineseCaptions: [ChineseCaption]?
            }
            let legacy = try decoder.decode(Legacy.self, from: data)
            doc = ClassDocument(title: legacy.sampleName.isEmpty ? "导入的课堂" : legacy.sampleName, course: Course.defaults[2])
            doc.startedAt = legacy.createdAt; doc.duration = legacy.durationSeconds
            doc.lines = legacy.lines; doc.captions = legacy.chineseCaptions ?? []
        }
        guard Self.validDerivedData(doc), doc.lines.count <= 50_000, doc.duration.isFinite, doc.duration >= 0, doc.duration <= 604_800,
              Set(doc.lines.map(\.id)).count == doc.lines.count,
              Set(doc.captions.map(\.id)).count == doc.captions.count,
              doc.lines.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start && $0.end <= 604_800 }),
              doc.captions.allSatisfy({ $0.audioStart.isFinite && $0.audioStart >= 0 && $0.audioStart <= 604_800 }),
              doc.bookmarks.allSatisfy({ $0.seconds.isFinite && $0.seconds >= 0 && $0.seconds <= 604_800 }) else {
            throw CaptureError("记录包含无效时间、重复段落或异常大小，未导入")
        }
        doc.id = UUID(); doc.audioFilename = nil; doc.audioParts = nil; doc.deletedAt = nil; doc.status = "imported"
        doc.source = "archive"; try save(doc); return doc.id
    }
    func attachAudio(_ url: URL, to doc: inout ClassDocument) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let ext = url.pathExtension.lowercased().filter { $0.isLetter || $0.isNumber }
        let name = "audio-" + UUID().uuidString + "." + (ext.isEmpty ? "caf" : String(ext.prefix(8)))
        try FileManager.default.copyItem(at: url, to: folder(doc.id).appendingPathComponent(name))
        doc.audioFilename = name; doc.audioParts = nil; try save(doc)
    }
    func exports(_ doc: ClassDocument, includeAudio: Bool) throws -> [URL] {
        try save(doc)
        // Dedicated export copy prevents sharing stale snapshots or the entire private library.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ClairExports").appendingPathComponent(doc.id.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let markdown = directory.appendingPathComponent("课堂笔记.md")
        let subtitle = directory.appendingPathComponent("法中字幕.srt")
        let json = directory.appendingPathComponent("class.json")
        try ClassExport.markdown(doc).write(to: markdown, atomically: true, encoding: .utf8)
        try ClassExport.srt(doc).write(to: subtitle, atomically: true, encoding: .utf8)
        try Self.encoder().encode(doc).write(to: json, options: Self.libraryWriteOptions)
        var files = [markdown, subtitle, json]
        if includeAudio { files.append(contentsOf: audioSources(doc).map(\.url)) }
        return files
    }
}
