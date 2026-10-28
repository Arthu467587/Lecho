import Foundation

enum ClassroomState { case idle, preparing, recording, paused, stopping }
enum CaptureBackgroundAction: Equatable { case continueMicrophone, pauseImportedFile, keepPaused, cancelPreparation, saveOnly }

enum ClassroomLifecycle {
    static func backgroundAction(state: ClassroomState, source: String) -> CaptureBackgroundAction {
        switch state {
        case .preparing: return .cancelPreparation
        case .recording: return source == "microphone" ? .continueMicrophone : .pauseImportedFile
        case .paused: return .keepPaused
        case .idle, .stopping: return .saveOnly
        }
    }
    static func inputRouteChanged(previous: [String], current: [String]) -> Bool {
        Set(previous) != Set(current)
    }
}

enum CaptionAppearance {
    static let storageKey = "Clair.captionFontSize"
    static let sizes: [Double] = [17, 21, 26, 32]
    static let defaultSize = 21.0
    static func normalized(_ value: Double) -> Double { sizes.contains(value) ? value : defaultSize }
    static func adjusted(_ value: Double, by step: Int) -> Double {
        let index = sizes.firstIndex(of: normalized(value)) ?? 1
        return sizes[max(0, min(sizes.count - 1, index + step))]
    }
    static func frenchSize(_ value: Double, bilingual: Bool) -> Double {
        let size = normalized(value)
        return bilingual ? max(17, size - 5) : size
    }
}

// Capture pause time at the user action, rather than when a suspended file task next wakes up.
struct CapturePauseClock {
    private(set) var totalPaused = 0.0
    private var pausedAt: Double?
    mutating func pause(at time: Double) { if pausedAt == nil { pausedAt = time } }
    mutating func resume(at time: Double) {
        if let began = pausedAt { totalPaused += max(0, time - began); pausedAt = nil }
    }
}
