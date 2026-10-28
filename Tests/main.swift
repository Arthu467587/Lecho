import Foundation

func event(_ start: Double, _ duration: Double, _ text: String, _ final: Bool) -> CaptionEvent {
    CaptionEvent(start: start, duration: duration, text: text, isFinal: final,
                 receivedSeconds: start + duration + 0.3, deliveryLagSeconds: 0.3,
                 confidence: nil, afterStop: false)
}

var ledger = TranscriptLedger()
ledger.receive(event(0, 1, "soit une", false))
let id = ledger.lines[0].id
ledger.receive(event(0, 2, "Soit une fonction.", true))
assert(ledger.lines.count == 1 && ledger.lines[0].id == id)
assert(ledger.finalizedTranscript == "Soit une fonction.")
ledger.receive(event(0, 1, "soit", false))
assert(ledger.transcript == "Soit une fonction.", "Late provisional must not erase final")
ledger.receive(event(2, 1, "elle converge", false))
ledger.receive(event(3, 1, "uniformément", false))
ledger.receive(event(2, 2, "Elle converge uniformément.", true))
assert(ledger.lines.count == 2, "A final spanning two drafts must replace both")
assert(ledger.finalizedTranscript == "Soit une fonction. Elle converge uniformément.")
ledger.receive(event(2.005, 2, "Elle ne converge pas uniformément.", true))
assert(ledger.lines.count == 2 && ledger.transcript.contains("ne converge pas"))
ledger.receive(event(3.99, 2, "La limite est nulle.", true))
assert(ledger.lines.count == 3, "Small boundary overlap must not drop the preceding final sentence")
ledger.receive(event(.nan, 1, "invalid", true))
ledger.receive(event(9, -1, "invalid", true))
ledger.receive(event(9, 1, "   ", true))
assert(ledger.lines.count == 3)
assert(percentile([], 0.95) == nil)
assert(percentile([0.3, 0.1, .nan, 0.2], 0.5) == 0.2)
assert(percentile([0.3, 0.1, 0.2], 0.95) == 0.3)
print("PASS: caption revisions, finalization, overlap, stable IDs, invalid ranges, percentiles")

let lineID = UUID()
let sourceLine = CaptionLine(id: lineID, start: 2, end: 12,
    text: "Une force perpendiculaire au déplacement ne travaille pas. La masse est constante.", isFinal: false)
let pieces = TranslationChunks.slices([sourceLine])
assert(pieces.count == 2 && pieces[0].french.contains("ne travaille pas."))
assert(pieces[0].closedClause && !pieces[0].isFinal)
var plan = TranslationPlan()
plan.observe(pieces, now: 0)
assert(plan.next(now: 0.05) == nil, "Keep only a short debounce before the first caption")
let submitted = plan.next(now: 1)!
assert(submitted.slice.id == pieces[0].id)
assert(plan.next(now: 1)?.slice.id == pieces[1].id, "Allow another distinct unit")
assert(plan.next(now: 1) == nil, "Do not duplicate in-flight requests")
var revised = pieces
revised[0].french = "Cette force ne travaille pas."
plan.observe(revised, now: 1.2)
plan.finish(id: submitted.slice.id, submitted: submitted.slice.french, success: true)
let replacement = plan.next(now: 2.3)!
assert(replacement.slice.french == revised[0].french, "An old completion must not suppress newer French")
plan.finish(id: replacement.slice.id, submitted: replacement.slice.french, success: false)
assert(plan.next(now: 3) == nil, "No automatic failure retry loop")
plan.retryFailed()
assert(plan.next(now: 3)?.slice.french == replacement.slice.french)
let longWords = (0..<110).map { "mot\($0)" }.joined(separator: " ")
let chunks = TranslationChunks.slices([CaptionLine(start: 0, end: 20, text: longWords, isFinal: false)])
assert(chunks.count == 3 && chunks[0].french.split(separator: " ").count == 48)
assert(!chunks[2].closedClause)
let decimal = TranslationChunks.slices([CaptionLine(start: 0, end: 2, text: "La valeur est 3.14 mètres.", isFinal: true)])
assert(decimal.count == 1, "Do not split inside a decimal")
let keepAlive = try DeepSeekProtocol.delta(": keep-alive")
assert(keepAlive == nil)
let content = try DeepSeekProtocol.delta(#"data: {"choices":[{"delta":{"content":"不做功","reasoning_content":"hidden"}}]}"#)
assert(content?.content == "不做功")
let reasoning = try DeepSeekProtocol.delta(#"data: {"choices":[{"delta":{"reasoning_content":"hidden"}}]}"#)
assert(reasoning?.content == nil)
let doneDelta = try DeepSeekProtocol.delta("data: [DONE]")
assert(doneDelta?.done == true)
let usage = try DeepSeekProtocol.delta(#"data: {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5}}"#)
assert(usage?.promptTokens == 10 && usage?.completionTokens == 5)
let payload = DeepSeekProtocol.payload(french: "Elle ne travaille pas.", context: ["une force"], subject: "物理", glossary: "travail=功", model: "deepseek-flash")
assert((payload["thinking"] as? [String: String])?["type"] == "disabled")
assert(payload["stream"] as? Bool == true)
assert(payload["api_key"] == nil)
print("PASS: stable clause scheduling, bounded chunks, revision races, no duplicate requests, explicit retries, SSE content/usage and reasoning exclusion")

// Persistence and exports use original speech-segment ranges rather than fabricated word timing.
let course = Course.defaults[0]
var doc = ClassDocument(title: "Analyse", course: course)
doc.lines = [sourceLine]
var initialSegmentation = RollingSegmentation()
doc.semanticUnits = initialSegmentation.update([sourceLine], now: 0, flush: true)
doc.duration = 12
doc.notes = "我的笔记"
doc.bookmarks = [ClassBookmark(seconds: 4, text: "条件")]
doc.captions = pieces.map { slice in
    ChineseCaption(id: slice.id, french: slice.french, chinese: "中文", status: "complete",
        sourceFinal: slice.isFinal, audioStart: slice.audioStart, translatedFrench: slice.french)
}
assert(doc.unfinishedCount == 0)
doc.captions[0].translatedFrench = "old revision"
assert(doc.unfinishedCount == 1)
assert(ClassExport.chinese(for: sourceLine, in: doc).contains("待更新"))
doc.captions.removeLast()
assert(doc.unfinishedCount == 2, "Missing rows and old French revisions are both unfinished")
assert(ClassExport.srt(doc).contains("00:00:02,000 --> 00:00:12,000"))
assert(ClassExport.srt(doc).components(separatedBy: " --> ").count == 2, "One cue per speech segment")
assert(ClassExport.markdown(doc).contains("我的笔记"))
assert(ClassExport.markdown(doc).contains("[00:04] 条件"))
assert(ClassExport.clock(3661) == "1:01:01")
assert(ClassExport.stamp(1.2349) == "00:00:01,234")
for invalid in ["../audio.caf", "..\\audio.caf", "D:audio.caf", "..", ".", ""] {
    assert(ClassExport.validatedAudioName(invalid) == nil)
}
assert(ClassExport.validatedAudioName("audio.caf") == "audio.caf")
assert(ClassExport.validatedAudioName(nil) == nil)
let encoded = try JSONEncoder().encode(doc)
let decoded = try JSONDecoder().decode(ClassDocument.self, from: encoded)
assert(decoded.id == doc.id && decoded.bookmarks.count == 1 && decoded.lines == doc.lines)
assert(!String(decoding: encoded, as: UTF8.self).contains("api_key"))
var restored = TranslationPlan()
restored.observe(pieces, now: 0)
restored.finish(id: pieces[0].id, submitted: pieces[0].french, success: true)
assert(restored.next(now: 0, flush: true)?.slice.id == pieces[1].id, "Completed translations must not be charged again during repair")
print("PASS: archive round trip, missing/revised translation recovery, bilingual export markers, segment timestamps, audio path traversal rejection")
assert(!CaptionAmbiguity.hasMarker("Cette condition est nécessaire, mais pas suffisante."))
let uncertainTranslation = "〔存疑〕对任意 ε > 0，x ∈ [a,b]；并不意味着 v = 3.14 m/s。〔存疑〕"
assert(CaptionAmbiguity.hasMarker(uncertainTranslation))
assert(CaptionAmbiguity.displayText(uncertainTranslation) == "对任意 ε > 0，x ∈ [a,b]；并不意味着 v = 3.14 m/s。")
assert(uncertainTranslation.hasPrefix("〔存疑〕"), "Display conversion must not mutate its source")
assert(CaptionAmbiguity.displayText("〔存疑〕 \n 〔存疑〕") == "这段内容暂不明确")
assert(CaptionAmbiguity.displayText("").isEmpty)
assert(CaptionAmbiguity.displayText("  不成立。  ") == "  不成立。  ")
assert(CaptionAmbiguity.displayText("〔未完成/待更新〕〔存疑〕N不依赖x") == "〔未完成/待更新〕N不依赖x")
var ambiguousDocument = doc
ambiguousDocument.captions[0].chinese = uncertainTranslation
let ambiguityJSON = try JSONEncoder().encode(ambiguousDocument)
assert(String(decoding: ambiguityJSON, as: UTF8.self).contains("〔存疑〕"))
assert(ClassExport.markdown(ambiguousDocument).contains("〔存疑〕"))
assert(ClassExport.srt(ambiguousDocument).contains("〔存疑〕"))
print("PASS: ambiguity display preserves source, formulas, negation, incomplete markers and export uncertainty")

assert(CaptionAppearance.sizes == [17, 21, 26, 32])
assert(CaptionAppearance.normalized(.nan) == 21 && CaptionAppearance.normalized(500) == 21)
assert(CaptionAppearance.adjusted(17, by: -1) == 17 && CaptionAppearance.adjusted(32, by: 1) == 32)
assert(CaptionAppearance.adjusted(21, by: 1) == 26 && CaptionAppearance.adjusted(26, by: -1) == 21)
assert(CaptionAppearance.frenchSize(32, bilingual: false) == 32)
assert(CaptionAppearance.frenchSize(21, bilingual: true) == 17)
assert(ClassroomLifecycle.backgroundAction(state: .recording, source: "microphone") == .continueMicrophone)
assert(ClassroomLifecycle.backgroundAction(state: .recording, source: "imported") == .pauseImportedFile)
assert(ClassroomLifecycle.backgroundAction(state: .preparing, source: "microphone") == .cancelPreparation)
assert(ClassroomLifecycle.backgroundAction(state: .paused, source: "microphone") == .keepPaused)
assert(ClassroomLifecycle.backgroundAction(state: .idle, source: "microphone") == .saveOnly)
assert(!ClassroomLifecycle.inputRouteChanged(previous: ["built-in"], current: ["built-in"]))
assert(ClassroomLifecycle.inputRouteChanged(previous: ["built-in"], current: []))
assert(ClassroomLifecycle.inputRouteChanged(previous: ["built-in"], current: ["usb"]))
let preferences = UserDefaults(suiteName: "Clair.tests.caption-size")!
preferences.set(32.0, forKey: CaptionAppearance.storageKey)
assert(CaptionAppearance.normalized(preferences.double(forKey: CaptionAppearance.storageKey)) == 32)
preferences.removePersistentDomain(forName: "Clair.tests.caption-size")
print("PASS: caption size boundaries/persistence and microphone/import/preparing/paused background policy")

var pauseClock = CapturePauseClock()
pauseClock.pause(at: 10); pauseClock.pause(at: 15); pauseClock.resume(at: 130)
assert(pauseClock.totalPaused == 120, "Count suspension even when no file-task iteration ran")
pauseClock.resume(at: 135); assert(pauseClock.totalPaused == 120)
pauseClock.pause(at: 140); pauseClock.resume(at: 145); assert(pauseClock.totalPaused == 125)
print("PASS: file timing pause across background suspension, repeated pause and resume")

// New 1.2 runtime assertions: execute with scripts/check-mac.sh on a Mac.
func speechLine(_ text: String, _ start: Double = 0) -> CaptionLine {
    CaptionLine(start: start, end: start+1, text: text, isFinal: true)
}
let condition = [speechLine("Si une suite converge uniformément."), speechLine("Alors elle converge ponctuellement.", 1)]
var semantic = RollingSegmentation()
let joined = semantic.update(condition, now: 0)
assert(joined.count == 1 && joined[0].fragments.count == 2)
assert(joined[0].text == condition.map(\.text).joined(separator: " "))
assert(joined[0].start == 0 && joined[0].end == 2, "Merged unit retains original audio ranges")
let independent = [speechLine("La suite converge ponctuellement."), speechLine("Elle ne converge pas uniformément.", 1)]
var independentSegmenter = RollingSegmentation()
assert(independentSegmenter.update(independent, now: 0).count == 2, "Do not merge related independent propositions")
let quantified = [speechLine("Pour tout epsilon strictement positif."), speechLine("Il existe un entier N.", 1)]
var quantifiedSegmenter = RollingSegmentation()
assert(quantifiedSegmenter.update(quantified, now: 0).count == 1)
let protectedWords = speechLine("M. Dupont pose x = 3.14 mètres. Puis il continue.")
assert(FrenchSegmentation.fragments([protectedWords]).count == 2)
let bracketed = speechLine("On écrit (x. puis y) avant de conclure.")
assert(FrenchSegmentation.fragments([bracketed]).count == 1)
assert(TranslationChunks.slices([speechLine((0..<38).map { "mot\($0)" }.joined(separator: " "))]).count == 1)
let many = (0..<5).map { speechLine("Proposition \($0) est vraie.", Double($0)) }
var windows = RollingSegmentation()
_ = windows.update(many, now: 0)
_ = windows.update(many, now: 1.1)
let window = windows.reviewWindow(now: 1.1)!
assert(window.fragments.count == 5 && window.firstMutable == 2)
assert(!windows.apply([0], for: window, now: 1.2), "Read-only previous context cannot be merged")
assert(!windows.apply([2,2], for: window, now: 1.2), "Duplicate decisions are rejected")
assert(windows.apply([2], for: window, now: 1.2))
let revisedGroups = windows.update(many, now: 1.2)
assert(revisedGroups.count == 4 && revisedGroups.flatMap(\.fragments).map(\.text) == many.map(\.text))
_ = windows.update(many + [speechLine("Une autre proposition suit.", 5)], now: 2)
assert(!windows.apply([2], for: window, now: 3.2), "Late window response cannot affect a newer source")
_ = windows.update(many, now: 20, flush: true)
assert(windows.units.allSatisfy(\.locked) && windows.reviewWindow(now: 21) == nil)
let boundaryJSON = Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"{\"merge_after\":[2]}"}}]}"#.utf8)
let parsedBoundary = try BoundaryReviewProtocol.parse(boundaryJSON)
assert(parsedBoundary == [2])
for bad in [#"{"choices":[{"finish_reason":"stop","message":{"content":"{\"merge_after\":[true]}"}}]}"#,
            #"{"choices":[{"finish_reason":"length","message":{"content":"{\"merge_after\":[]}"}}]}"#] {
    do { _ = try BoundaryReviewProtocol.parse(Data(bad.utf8)); assertionFailure("Invalid review must fail closed") } catch {}
}
var editDoc = ClassDocument(title: "Edited", course: course)
editDoc.lines = independent
editDoc.semanticUnits = independentSegmenter.update(independent, now: 1, flush: true)
editDoc.captions = editDoc.translationSlices.map {
    ChineseCaption(id: $0.id, french: $0.french, chinese: "原中文", status: "complete", sourceFinal: true, audioStart: $0.audioStart, translatedFrench: $0.french)
}
let rawBefore = editDoc.lines
let editedID = editDoc.displayLines[0].id
try editDoc.correct(editedID, text: "La suite ne converge pas.")
assert(editDoc.lines == rawBefore && editDoc.unfinishedCount == 1)
assert(editDoc.displayLines[0].text == "La suite ne converge pas.")
assert(ClassExport.markdown(editDoc).contains("原始识别（保留）"))
assert(editDoc.captions[1].status == "complete", "Only changed unit becomes stale")
editDoc.status = "suspended"; editDoc.recordingEnabled = true
editDoc.audioParts = [ClassAudioPart(filename: "first.caf", start: 0, duration: 2), ClassAudioPart(filename: "second.caf", start: 2, duration: 3)]
let continued = try JSONDecoder().decode(ClassDocument.self, from: JSONEncoder().encode(editDoc))
assert(continued.id == editDoc.id && continued.isResumable && continued.audioParts?.count == 2)
assert(continued.correctedText == editDoc.correctedText)
assert(ClassContinuation.validParts(continued.audioParts!))
assert(!ClassContinuation.validParts([ClassAudioPart(filename: "../bad.caf", start: 0, duration: 1)]))
assert(!ClassContinuation.validParts([ClassAudioPart(filename: nil, start: .nan, duration: 1)]))
var continuedLedger = TranscriptLedger(lines: independent)
let newEvent = event(0, 1, "Une nouvelle phrase.", true)
continuedLedger.receive(ClassContinuation.offset(newEvent, by: 2))
assert(continuedLedger.lines.count == 3 && continuedLedger.lines.last?.start == 2 && newEvent.start == 0)
var legacy = ClassDocument(title: "Legacy", course: course)
legacy.lines = [sourceLine]; legacy.captions = TranslationChunks.legacySlices(legacy.lines).map {
    ChineseCaption(id: $0.id, french: $0.french, chinese: "已完成", status: "complete", sourceFinal: true, audioStart: $0.audioStart, translatedFrench: $0.french)
}
let legacyDecoded = try JSONDecoder().decode(ClassDocument.self, from: JSONEncoder().encode(legacy))
assert(legacyDecoded.semanticUnits == nil && legacyDecoded.audioParts == nil)
let legacyID = legacy.id; legacy.prepareContinuation()
assert(legacy.id == legacyID && legacy.captions.count == 1 && legacy.unfinishedCount == 0)
print("PASS: French boundaries, protected punctuation, five-unit review, source/time preservation, stale response rejection, corrections, continuation/legacy fields and audio-part validation")

// Final-review regressions. These execute on Mac; Windows source checks are separate.
for question in ["Qui connaît une démonstration ?", "Que vaut la limite ?"] {
    var interrogatives = RollingSegmentation()
    let result = interrogatives.update([speechLine("La fonction est continue."), speechLine(question, 1)], now: 0)
    assert(result.count == 2 && result[1].text == question, "An independent question must not be attached to a complete statement")
}
var relative = RollingSegmentation()
assert(relative.update([speechLine("On choisit une fonction qui."), speechLine("Admet une dérivée.", 1)], now: 0).count == 1)
let drained = CaptureDrain(outputFrames: 7_999, outputRate: 16_000, inputFrames: 24_000, inputRate: 48_000)
assert(drained.seconds(for: "imported") == 0.5)
assert(drained.seconds(for: "microphone") == Double(7_999)/16_000)
let cursorFrames: [Int64] = [1, 2_047, 2_048, 9_999, 24_000, 156_789]
for frame in cursorFrames {
    assert(ClassContinuation.frameOffset(Double(frame)/44_100, sampleRate: 44_100) == frame, "Source cursor must round trip exactly rather than use the throttled meter")
}
assert(ClassContinuation.frameOffset(.nan, sampleRate: 48_000) == 0)
assert(ClassContinuation.frameOffset(-1, sampleRate: 48_000) == 0)
print("PASS: standalone interrogatives, incomplete relative join, accepted-frame cursor and source/output duration distinction")

// A continuously changing draft must not block review of the preceding stable five sentences.
var continuous = RollingSegmentation()
var draft = CaptionLine(start: 5, end: 6, text: "La phrase en cours", isFinal: false)
_ = continuous.update(many + [draft], now: 0)
assert(continuous.reviewWindow(now: 0.5) == nil, "Wait for the stable window rather than send every ASR change")
draft.text += " continue"
_ = continuous.update(many + [draft], now: 1.1)
let continuousWindow = continuous.reviewWindow(now: 1.1)!
assert(continuousWindow.fragments.map(\.text) == many.map(\.text))
assert(continuousWindow.firstMutable == 2 && continuousWindow.fragments.allSatisfy(\.isFinal))
assert(continuous.units.filter(\.locked).count == 2, "Drafts cannot prematurely lock an extra stable sentence")
draft.text += " encore"
_ = continuous.update(many + [draft], now: 1.3)
assert(continuous.reviewWindow(now: 1.3) == continuousWindow, "An unrelated live draft does not invalidate an unchanged stable review")
assert(continuous.apply([2], for: continuousWindow, now: 1.3))
let continuousUnits = continuous.update(many + [draft], now: 1.3)
assert(continuousUnits.flatMap(\.fragments).map(\.text) == (many + [draft]).map(\.text))
var newFinal = draft; newFinal.isFinal = true; newFinal.text = "La phrase en cours est terminée."
_ = continuous.update(many + [newFinal], now: 1.4)
assert(continuous.reviewWindow(now: 1.4) == continuousWindow, "A new final sentence must stabilize before entering the review")
_ = continuous.update(many + [newFinal], now: 2.5)
assert(!continuous.apply([2], for: continuousWindow, now: 2.5), "An advanced stable window rejects a late response")
print("PASS: continuous-speech draft exclusion, stable review capacity and stale-window rejection")

// 1.3: commas appear first; completed initial captions gate later merges.
let commaLine = speechLine("La vitesse est nulle, l'accélération ne l'est pas.")
let commaFragments = FrenchSegmentation.fragments([commaLine])
let withoutCommas = FrenchSegmentation.fragments([speechLine((0..<30).map { "mot\($0)" }.joined(separator: " "))])
assert(withoutCommas.count == 3 && withoutCommas[0].text.split(separator: " ").count == 12,
       "Long unpunctuated speech must expose stable first-pass chunks before its final punctuation")
assert(commaFragments.count == 2 && commaFragments[0].text == "La vitesse est nulle,")
assert(commaFragments[0].closed)
assert(FrenchSegmentation.fragments([speechLine("La valeur est 3,14 mètres, puis elle change.")]).count == 2)
var fastClauses = RollingSegmentation()
let initialClauses = fastClauses.update([commaLine], now: 0, translatedFragments: [:])
assert(initialClauses.count == 2, "The first translation must not wait for a semantic merge")
var firstPass = FirstPassCaptions()
let initialChinese = initialClauses.enumerated().map { index, unit in
    ChineseCaption(id: unit.slice.id, french: unit.text, chinese: index == 0 ? "速度为零，" : "加速度不为零。",
        status: "complete", sourceFinal: false, audioStart: unit.start, translatedFrench: unit.text)
}
firstPass.record(units: initialClauses, captions: initialChinese)
let combined = fastClauses.update([commaLine], now: 1.2, translatedFragments: firstPass.texts)
assert(combined.count == 1 && combined[0].text == commaLine.text)
assert(FirstPassCaptions.provisionalChinese(for: combined[0], previousUnits: initialClauses, captions: initialChinese) == "速度为零， 加速度不为零。")
var changedComma = commaLine; changedComma.text = "La vitesse n'est pas nulle, l'accélération ne l'est pas."
assert(fastClauses.update([changedComma], now: 1.3, translatedFragments: firstPass.texts).count == 2,
       "Old completed text cannot authorize a merge after a true ASR revision")
let oldFragment = SpeechFragment(id: commaLine.id, sourceID: commaLine.id, text: commaLine.text,
    start: commaLine.start, end: commaLine.end, isFinal: true, closed: true)
var oldCommaArchive = RollingSegmentation(seed: [SemanticUnit(fragments: [oldFragment], locked: true)])
assert(oldCommaArchive.update([commaLine], now: 0, translatedFragments: [:]).first?.fragments.count == 1,
       "Adding comma boundaries must not retranslate or regroup an unchanged locked archive")
var quickPlan = TranslationPlan()
quickPlan.observe(initialClauses.map(\.slice), now: 0)
assert(quickPlan.next(now: 0.1) == nil)
assert(quickPlan.next(now: 0.15)?.slice.id == initialClauses[0].slice.id,
       "A closed comma clause is eligible at 120ms, without ASR finality")
var priorities = TranslationPlan()
priorities.observe([initialClauses[0].slice], now: 0)
priorities.finish(id: initialClauses[0].slice.id, submitted: initialClauses[0].text, success: true)
priorities.observe(combined.map(\.slice) + [initialClauses[1].slice], now: 1, secondaryIDs: [combined[0].slice.id])
assert(priorities.next(now: 1.2)?.slice.id == initialClauses[1].slice.id, "Fresh captions precede merged-text repairs")
assert(priorities.next(now: 1.2, allowRevisions: false) == nil)
assert(priorities.next(now: 1.2, allowRevisions: true)?.submittedFrench != nil)
print("PASS: comma immediacy, decimal comma, first-pass merge gate, provisional Chinese, archive compatibility and first-pass priority")

// Whole-branch review: chained merges, reverse splits, and persisted repair identity.
let mergeA = SemanticUnit(fragments: FrenchSegmentation.fragments([speechLine("Si la vitesse est nulle,")]))
let mergeB = SemanticUnit(fragments: FrenchSegmentation.fragments([speechLine("alors le mouvement s'arrête,", 1)]))
let mergeC = SemanticUnit(fragments: FrenchSegmentation.fragments([speechLine("mais l'accélération peut varier.", 2)]))
let mergeAB = SemanticUnit(fragments: mergeA.fragments + mergeB.fragments)
let mergeABC = SemanticUnit(fragments: mergeAB.fragments + mergeC.fragments)
func completedRow(_ unit: SemanticUnit, _ text: String) -> ChineseCaption {
    ChineseCaption(id: unit.slice.id, french: unit.text, chinese: text, status: "complete",
        audioStart: unit.start, translatedFrench: unit.text)
}
let aRow = completedRow(mergeA, "若速度为零，")
let bRow = completedRow(mergeB, "则运动停止，")
let cRow = completedRow(mergeC, "但加速度可以变化。")
var pendingAB = ChineseCaption(id: mergeAB.slice.id, french: mergeAB.text, chinese: "若速度为零， 则运动停止，",
    status: "streaming", audioStart: mergeAB.start, translatedFrench: mergeA.text, provisionalFrench: mergeAB.text)
for phase in ["stale", "streaming", "failed", "cancelled"] {
    pendingAB.status = phase
    assert(FirstPassCaptions.provisionalChinese(for: mergeABC, previousUnits: [mergeAB, mergeC], captions: [pendingAB, cRow]) == "若速度为零， 则运动停止， 但加速度可以变化。",
           "Chaining a merge must retain C even when AB is not complete")
}
var history = FirstPassCaptions()
history.record(units: [mergeA, mergeB], captions: [aRow, bRow])
history.record(units: [mergeAB], captions: [completedRow(mergeAB, "若速度为零，则运动停止，")])
let splitRows = [mergeA, mergeB].map { history.completed(for: $0.slice)! }
assert(splitRows.map(\.chinese) == [aRow.chinese, bRow.chinese], "A review split restores each component, not AB on A and blank B")
var splitPlan = TranslationPlan()
splitPlan.observe([mergeA.slice, mergeB.slice], now: 0)
for row in splitRows { splitPlan.finish(id: row.id, submitted: row.french, success: true) }
assert(splitPlan.pendingCount == 0 && splitPlan.next(now: 1) == nil, "Restored complete components do not consume fresh-caption slots")
let savedPendingAB = try JSONDecoder().decode(ChineseCaption.self, from: JSONEncoder().encode(pendingAB))
assert(savedPendingAB.provisionalFrench == mergeAB.text && savedPendingAB.isSemanticRepair)
assert(savedPendingAB.coversProvisionalSource(mergeAB.text))
var restoredRepair = TranslationPlan()
restoredRepair.observe([mergeAB.slice, mergeC.slice], now: 0, secondaryIDs: [savedPendingAB.id])
assert(restoredRepair.next(now: 0.2, allowRevisions: false)?.slice.id == mergeC.slice.id)
assert(restoredRepair.next(now: 0.2, allowRevisions: false) == nil)
let repairAfterResume = restoredRepair.next(now: 0.2, allowRevisions: true)!
assert(repairAfterResume.secondaryRepair && repairAfterResume.submittedFrench == nil,
       "Resume preserves semantic repair identity even in a fresh translation plan")
var oldPartial = pendingAB; oldPartial.provisionalFrench = nil
let legacyPartial = try JSONDecoder().decode(ChineseCaption.self, from: JSONEncoder().encode(oldPartial))
assert(legacyPartial.provisionalFrench == nil && !legacyPartial.coversProvisionalSource(mergeAB.text))
var sourceCorrection = TranslationPlan()
sourceCorrection.observe([mergeA.slice], now: 0)
sourceCorrection.finish(id: mergeA.slice.id, submitted: mergeA.text, success: true)
var negated = mergeA.slice; negated.french = "Si la vitesse n'est pas nulle,"
sourceCorrection.observe([negated], now: 1)
let urgentCorrection = sourceCorrection.next(now: 1.2, allowRevisions: false)!
assert(!urgentCorrection.secondaryRepair && urgentCorrection.slice.french == negated.french,
       "A real ASR correction is primary; only semantic regrouping is a background repair")
print("PASS: chained provisional coverage, historical split recovery, persisted semantic repair identity, legacy optional field and urgent ASR correction")
