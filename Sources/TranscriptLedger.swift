import Foundation

struct CaptureError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct CaptionEvent: Codable, Sendable {
    var start: Double
    var duration: Double
    var text: String
    var isFinal: Bool
    var receivedSeconds: Double
    var deliveryLagSeconds: Double?
    var confidence: Double?
    var afterStop: Bool
}

struct CaptionLine: Codable, Identifiable, Equatable {
    var id = UUID()
    var start: Double
    var end: Double
    var text: String
    var isFinal: Bool
}

/// A result is a replacement for its time range, never an append-only text delta.
/// Kept independent of Speech/SwiftUI so the Mac checks can exercise it directly.
struct TranscriptLedger {
    private(set) var lines: [CaptionLine] = []
    init(lines: [CaptionLine] = []) { self.lines = lines }

    mutating func receive(_ event: CaptionEvent) {
        guard event.start.isFinite, event.duration.isFinite, event.duration >= 0 else { return }
        let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let end = event.start + event.duration
        // Never replace an already finalized range with a late provisional update.
        if !event.isFinal, lines.contains(where: {
            $0.isFinal && $0.start <= event.start + 0.02 && $0.end >= end - 0.02
        }) { return }
        let matching = lines.indices.filter { index in
            let line = lines[index]
            let overlaps = max(line.start, event.start) < min(line.end, end) - 0.001
            let sameStart = abs(line.start - event.start) < 0.02
            return sameStart || overlaps
        }
        // Final results can extend over earlier provisional rows. Clear all of them.
        // An overlapping final is superseded only by a new final result.
        let removable = matching.filter { index in
            let line = lines[index]
            if !line.isFinal { return true }
            // Small boundary overlaps must not delete the preceding finalized sentence.
            return event.isFinal && (abs(line.start - event.start) < 0.02
                || (event.start <= line.start + 0.02 && end >= line.end - 0.02))
        }
        let preservedID = removable.first.map { lines[$0].id } ?? UUID()
        for index in removable.reversed() { lines.remove(at: index) }
        lines.append(CaptionLine(id: preservedID, start: event.start, end: end,
                                 text: text, isFinal: event.isFinal))
        lines.sort { $0.start < $1.start }
    }

    var transcript: String { lines.map(\.text).joined(separator: " ") }
    var finalizedTranscript: String { lines.filter(\.isFinal).map(\.text).joined(separator: " ") }
}

func percentile(_ input: [Double], _ p: Double) -> Double? {
    let values = input.filter(\.isFinite).sorted()
    guard !values.isEmpty else { return nil }
    let index = Int(ceil(Double(values.count) * min(1, max(0, p)))) - 1
    return values[max(0, index)]
}
