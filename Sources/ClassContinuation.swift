import Foundation

struct CaptureDrain: Sendable {
    var outputFrames: Int64 = 0
    var outputRate: Double = 1
    var inputFrames: Int64 = 0
    var inputRate: Double = 1
    var outputSeconds: Double { Double(outputFrames) / max(1, outputRate) }
    var inputSeconds: Double { Double(inputFrames) / max(1, inputRate) }
    func seconds(for source: String) -> Double { source == "imported" ? inputSeconds : outputSeconds }
}

struct ClassAudioPart: Codable, Identifiable {
    var id = UUID()
    var filename: String?
    var start: Double
    var duration: Double
}

struct ClassAudioSource {
    var url: URL
    var start: Double
    var duration: Double
}

extension ClassDocument {
    var isResumable: Bool {
        deletedAt == nil && ["microphone", "imported"].contains(source) &&
        ["suspended", "interrupted"].contains(status) && duration.isFinite && duration >= 0
    }
    /// Freeze the previous capture epoch; a new microphone epoch never revises its predecessor.
    mutating func prepareContinuation() {
        if semanticUnits == nil {
            let previous = Dictionary(captions.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
            semanticUnits = lines.map { SemanticUnit(fragments: FrenchSegmentation.fragments([$0]), locked: true) }
                .filter { !$0.fragments.isEmpty }
            captions = (semanticUnits ?? []).map { unit in
                let original = lines.first { $0.id == unit.fragments[0].sourceID }!
                let slices = TranslationChunks.legacySlices([original])
                let rows = slices.compactMap { previous[$0.id] }
                let complete = rows.count == slices.count && zip(slices, rows).allSatisfy {
                    $0.1.status == "complete" && $0.1.translatedFrench == $0.0.french
                } && correctedText?[unit.id.uuidString] == nil
                return ChineseCaption(id: unit.id.uuidString + ":0", french: unit.text,
                    chinese: rows.map(\.chinese).joined(separator: " "), status: complete ? "complete" : "cancelled",
                    sourceFinal: true, audioStart: unit.start, translatedFrench: complete ? unit.text : nil)
            }
        }
        if let units = semanticUnits {
            semanticUnits = units.map { var unit = $0; unit.locked = true; return unit }
        }
        if source == "microphone", audioParts == nil {
            audioParts = duration > 0 ? [ClassAudioPart(filename: audioFilename, start: 0, duration: duration)] : []
        }
        if recordingEnabled == nil { recordingEnabled = audioFilename != nil }
    }
}

enum ClassContinuation {
    static func frameOffset(_ seconds: Double, sampleRate: Double) -> Int64 {
        let value = seconds * sampleRate
        guard value.isFinite, value > 0, value < Double(Int64.max) else { return 0 }
        return Int64(value.rounded())
    }
    static func offset(_ event: CaptionEvent, by seconds: Double) -> CaptionEvent {
        var result = event; result.start += seconds; return result
    }
    static func validParts(_ parts: [ClassAudioPart]) -> Bool {
        parts.allSatisfy {
            $0.start.isFinite && $0.duration.isFinite && $0.start >= 0 && $0.duration >= 0 &&
            $0.start + $0.duration <= 604_800 && ($0.filename == nil || ClassExport.validatedAudioName($0.filename) != nil)
        } && Set(parts.map(\.id)).count == parts.count
    }
}
