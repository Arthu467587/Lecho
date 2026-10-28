import Foundation

@main
struct TranslationFinalizationChecks {
    @MainActor static func main() {
        let first = CaptionLine(start: 0, end: 1, text: "La fonction est continue.", isFinal: true)
        let late = CaptionLine(start: 1, end: 2, text: "La limite existe.", isFinal: true)
        var doc = ClassDocument(title: "Finalization check", course: Course.defaults[0])
        doc.lines = [first]; doc.semanticUnits = []
        let translator = DeepSeekTranslation()
        translator.freezeForSave(doc, lines: doc.lines)
        translator.cancel()
        translator.observe([first, late])
        assert(translator.units.count == 1, "Cancelled live callbacks do not restart the session")
        translator.flushSegmentation(finalLines: [first, late])
        assert(translator.units.map(\.text) == [first.text, late.text], "Persist the late final speech after cancellation")
        assert(translator.units.allSatisfy(\.locked))
        assert(translator.captions.map(\.french) == [first.text, late.text])
        assert(translator.pendingCount == 0 && translator.attempts.isEmpty && !translator.canRetry,
               "Local final snapshot cannot start translation or review requests")

        var legacy = ClassDocument(title: "Legacy check", course: Course.defaults[0])
        legacy.lines = [CaptionLine(start: 0, end: 4,
            text: (0..<40).map { "mot\($0)" }.joined(separator: " "), isFinal: true)]
        let ids = legacy.translationSlices.map(\.id)
        // An empty repair scope suppresses all requests, even if this Mac already has a Keychain key.
        translator.restore(legacy, only: Set<UUID>(), live: false)
        translator.cancel()
        translator.flushSegmentation()
        assert(translator.units.isEmpty && translator.captions.map(\.id) == ids,
               "Ordinary repair finalization must retain legacy archive IDs")
        assert(translator.attempts.isEmpty)
        print("PASS: late final speech local persistence after cancellation and legacy repair IDs; no API requests")
    }
}
