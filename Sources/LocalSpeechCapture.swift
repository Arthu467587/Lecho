// Audio conversion and SpeechAnalyzer flow adapted from steinyanaa/Clair,
// commit 518f96b7c7d09344e28f6c54903924bd52dee3ac. See LICENSE-Clair.txt.
import Foundation
@preconcurrency import AVFoundation
import Speech
import CoreMedia

/// Own callback buffers before they leave the audio thread, as Clair does.
/// All conversion, recording and analyzer input timestamps share one serial queue.
final class PCMInput: @unchecked Sendable {
    let format: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let queue = DispatchQueue(label: "ClairLocalTest.convert", qos: .userInitiated)
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var writer: AVAudioFile?
    private var frames: Int64 = 0
    private var convertedInputFrames: Int64 = 0
    private var acceptedInputFrames: Int64 = 0
    private var acceptedInputRate = 1.0
    private var closed = false
    private var firstBuffer = true
    private var lastMeterTime = 0.0
    private let backlogLock = NSLock()
    private var queuedBuffers = 0
    private var overflowReported = false
    private let onOrigin: @Sendable (Double) -> Void
    private let onMeter: @Sendable (Float, Double, Double) -> Void
    private let onFailure: @Sendable (String) -> Void

    init(format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation,
         recordingURL: URL?, onOrigin: @escaping @Sendable (Double) -> Void,
         onMeter: @escaping @Sendable (Float, Double, Double) -> Void,
         onFailure: @escaping @Sendable (String) -> Void) throws {
        self.format = format
        self.continuation = continuation
        self.onOrigin = onOrigin; self.onMeter = onMeter; self.onFailure = onFailure
        if let recordingURL {
            writer = try AVAudioFile(forWriting: recordingURL, settings: format.settings,
                                     commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                  ofItemAtPath: recordingURL.path)
        }
    }

    func accept(_ buffer: AVAudioPCMBuffer) {
        let arrival = ProcessInfo.processInfo.systemUptime
        guard buffer.frameLength > 0,
              let owned = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
        backlogLock.lock()
        if queuedBuffers >= 96 {
            let report = !overflowReported; overflowReported = true; backlogLock.unlock()
            if report { queue.async { [self] in fail("音频处理持续积压，已保留现有内容。请关闭其他高负载应用后继续。") } }
            return
        }
        queuedBuffers += 1; backlogLock.unlock()
        owned.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let target = UnsafeMutableAudioBufferListPointer(owned.mutableAudioBufferList)
        for i in 0..<min(source.count, target.count) {
            if let src = source[i].mData, let dst = target[i].mData {
                memcpy(dst, src, Int(source[i].mDataByteSize))
            }
        }
        queue.async { [self] in
            defer { backlogLock.lock(); queuedBuffers -= 1; backlogLock.unlock() }
            guard !closed else { return }
            if firstBuffer {
                firstBuffer = false
                // Approximate source time zero: callback time minus the first buffer duration.
                onOrigin(arrival - Double(owned.frameLength) / owned.format.sampleRate)
            }
            if inputFormat != owned.format {
                inputFormat = owned.format
                converter = AVAudioConverter(from: owned.format, to: format)
            }
            let capacity = AVAudioFrameCount(Double(owned.frameLength) * format.sampleRate / owned.format.sampleRate + 256)
            guard let converter, let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                fail("无法转换麦克风音频格式。"); return
            }
            var supplied = false
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                if supplied { inputStatus.pointee = .noDataNow; return nil }
                supplied = true; inputStatus.pointee = .haveData; return owned
            }
            guard status != .error, conversionError == nil else {
                fail("音频转换失败：\(conversionError?.localizedDescription ?? "未知错误")"); return
            }
            convertedInputFrames += Int64(owned.frameLength)
            acceptedInputRate = owned.format.sampleRate
            guard output.frameLength > 0 else { return }
            do { try writer?.write(from: output) }
            catch { fail("保存课堂录音失败：\(error.localizedDescription)"); return }
            let time = CMTime(value: frames, timescale: Int32(format.sampleRate))
            frames += Int64(output.frameLength)
            if arrival - lastMeterTime >= 0.1 {
                lastMeterTime = arrival
                var rms: Float = 0
                if let samples = output.floatChannelData?[0] {
                    for i in 0..<Int(output.frameLength) { rms += samples[i] * samples[i] }
                    rms = sqrt(rms / Float(output.frameLength))
                } else if let samples = output.int16ChannelData?[0] {
                    for i in 0..<Int(output.frameLength) { let x = Float(samples[i]) / 32768; rms += x * x }
                    rms = sqrt(rms / Float(output.frameLength))
                }
                onMeter(min(1, rms * 7), Double(frames) / format.sampleRate,
                        ProcessInfo.processInfo.systemUptime - arrival)
            }
            switch continuation.yield(AnalyzerInput(buffer: output, bufferStartTime: time)) {
            case .enqueued(_): acceptedInputFrames = convertedInputFrames
            case .dropped(_):
                fail("法语识别处理积压，已保存现有课堂，请稍后继续。")
            case .terminated:
                closed = true; writer = nil
            @unknown default: break
            }
        }
    }

    // Called on the serial conversion queue: stop at the first failed source buffer.
    private func fail(_ message: String) {
        closed = true; writer = nil; continuation.finish(); onFailure(message)
    }
    func finish() async -> CaptureDrain {
        await withCheckedContinuation { (done: CheckedContinuation<CaptureDrain, Never>) in
            queue.async { [self] in
                closed = true; writer = nil
                continuation.finish()
                done.resume(returning: CaptureDrain(outputFrames: frames, outputRate: format.sampleRate,
                    inputFrames: acceptedInputFrames, inputRate: acceptedInputRate))
            }
        }
    }
}

@MainActor
final class LocalSpeechCapture {
    private(set) var stopTimedOut = false
    private(set) var drain = CaptureDrain()
    private var engine: AVAudioEngine?
    private var sink: PCMInput?
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?
    private var fileTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var tapInstalled = false
    private var paused = false
    private var pauseClock = CapturePauseClock()
    private var stopRequested = false
    private var inputRouteUIDs: [String] = []

    func cancelPreparation() { stopRequested = true }

    func pause() { pauseClock.pause(at: ProcessInfo.processInfo.systemUptime); paused = true; engine?.pause() }
    func resume() throws {
        if let engine { try engine.start() }
        pauseClock.resume(at: ProcessInfo.processInfo.systemUptime); paused = false
    }

    static func prepareFrench() async throws -> Locale {
        guard SpeechTranscriber.isAvailable else {
            throw CaptureError("这台设备当前不能运行 SpeechTranscriber。必须在真实 iPad 上测试；模拟器不作为支持结论。")
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "fr-FR")) else {
            throw CaptureError("这台设备的本地 SpeechTranscriber 不支持法语。")
        }
        let module = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        _ = try await AssetInventory.reserve(locale: locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        return locale
    }

    private func setup(recordingURL: URL?,
        event: @escaping @MainActor @Sendable (Double, Double, String, Bool, Double?) -> Void,
        origin: @escaping @MainActor @Sendable (Double) -> Void,
        meter: @escaping @MainActor @Sendable (Float, Double, Double) -> Void,
        failure: @escaping @MainActor @Sendable (String) -> Void) async throws {
        stopTimedOut = false; drain = CaptureDrain()
        paused = false; pauseClock = CapturePauseClock()
        let locale = try await Self.prepareFrench()
        try Task.checkCancellation(); guard !stopRequested else { throw CancellationError() }
        let preset = SpeechTranscriber.Preset.timeIndexedProgressiveTranscription
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: preset.transcriptionOptions,
            reportingOptions: preset.reportingOptions,
            attributeOptions: preset.attributeOptions.union([.transcriptionConfidence]))
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw CaptureError("法语识别器没有返回可用的音频格式。")
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(96))
        sink = try PCMInput(format: format, continuation: continuation, recordingURL: recordingURL,
            onOrigin: { time in Task { @MainActor in origin(time) } },
            onMeter: { level, seconds, lag in Task { @MainActor in meter(level, seconds, lag) } },
            onFailure: { message in Task { @MainActor in failure(message) } })
        resultsTask = Task { @MainActor in
            do {
                for try await result in transcriber.results {
                    guard !Task.isCancelled else { break }
                    var weight = 0.0, count = 0
                    for run in result.text.runs {
                        if let value = run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self] {
                            let length = result.text.characters[run.range].count
                            weight += value * Double(length); count += length
                        }
                    }
                    event(result.range.start.seconds, result.range.duration.seconds,
                          String(result.text.characters), result.isFinal,
                          count > 0 ? weight / Double(count) : nil)
                }
            } catch {
                if !Task.isCancelled { failure("法语识别中断：\(error.localizedDescription)") }
            }
        }
        try await analyzer.prepareToAnalyze(in: format)
        try Task.checkCancellation(); guard !stopRequested else { throw CancellationError() }
        try await analyzer.start(inputSequence: stream)
    }

    func startMicrophone(recordingURL: URL?,
        event: @escaping @MainActor @Sendable (Double, Double, String, Bool, Double?) -> Void,
        origin: @escaping @MainActor @Sendable (Double) -> Void,
        meter: @escaping @MainActor @Sendable (Float, Double, Double) -> Void,
        failure: @escaping @MainActor @Sendable (String) -> Void) async throws -> String {
        stopRequested = false; drain = CaptureDrain()
        guard await AVAudioApplication.requestRecordPermission() else {
            throw CaptureError("请在 iPad 设置中允许 L'écho 使用麦克风。")
        }
        try Task.checkCancellation(); guard !stopRequested else { throw CancellationError() }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker])
        try session.setActive(true)
        do {
            try await setup(recordingURL: recordingURL, event: event, origin: origin, meter: meter, failure: failure)
            guard let sink else { throw CaptureError("识别尚未就绪。") }
            try Task.checkCancellation(); guard !stopRequested else { throw CancellationError() }
            let engine = AVAudioEngine()
            self.engine = engine
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError("没有可用的麦克风输入。") }
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in sink.accept(buffer) }
            tapInstalled = true
            engine.prepare(); try engine.start()
            inputRouteUIDs = session.currentRoute.inputs.map(\.uid)
            observers = [
                NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { notification in
                    guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                          let type = AVAudioSession.InterruptionType(rawValue: raw), type == .began else { return }
                    Task { @MainActor in failure("系统中断了音频会话，已结束并保存课堂。请检查输入设备后从课堂库继续。") }
                },
                NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.engine != nil, !self.stopRequested else { return }
                        let current = AVAudioSession.sharedInstance().currentRoute.inputs.map(\.uid)
                        guard ClassroomLifecycle.inputRouteChanged(previous: self.inputRouteUIDs, current: current) else { return }
                        self.inputRouteUIDs = current
                        failure("音频输入设备发生变化，已结束并保存课堂。请检查麦克风后从课堂库继续。")
                    }
                }
            ]
            return session.currentRoute.inputs.map { $0.portName + " (" + $0.portType.rawValue + ")" }.joined(separator: ", ")
                + " · \(Int(format.sampleRate)) Hz"
        } catch {
            await stop(); throw error
        }
    }

    func startFile(_ url: URL, fromSeconds: Double = 0,
        event: @escaping @MainActor @Sendable (Double, Double, String, Bool, Double?) -> Void,
        origin: @escaping @MainActor @Sendable (Double) -> Void,
        meter: @escaping @MainActor @Sendable (Float, Double, Double) -> Void,
        failure: @escaping @MainActor @Sendable (String) -> Void,
        completed: @escaping @MainActor @Sendable () -> Void) async throws {
        stopRequested = false; drain = CaptureDrain()
        try await setup(recordingURL: nil, event: event, origin: origin, meter: meter, failure: failure)
        guard let sink else { throw CaptureError("识别尚未就绪。") }
        let file = try AVAudioFile(forReading: url)
        let startFrame = min(file.length, ClassContinuation.frameOffset(fromSeconds, sampleRate: file.processingFormat.sampleRate))
        guard startFrame < file.length else { throw CaptureError("这份音频已经转写到结尾。") }
        file.framePosition = startFrame
        // Absolute scheduling avoids accumulating a per-buffer sleep/conversion drift.
        fileTask = Task { @MainActor in
            let began = ProcessInfo.processInfo.systemUptime
            do {
                while file.framePosition < file.length && !Task.isCancelled {
                    while paused && !Task.isCancelled { try await Task.sleep(for: .milliseconds(50)) }
                    try Task.checkCancellation()
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 2048) else {
                        throw CaptureError("无法分配音频缓冲区。")
                    }
                    try file.read(into: buffer)
                    while true {
                        try Task.checkCancellation()
                        if paused { try await Task.sleep(for: .milliseconds(50)); continue }
                        let due = began + pauseClock.totalPaused + Double(file.framePosition-startFrame) / file.processingFormat.sampleRate
                        let wait = due - ProcessInfo.processInfo.systemUptime
                        if wait <= 0 { break }
                        try await Task.sleep(for: .seconds(min(wait, 0.05)))
                    }
                    sink.accept(buffer)
                }
                if !Task.isCancelled { completed() }
            } catch {
                if !Task.isCancelled { failure("导入音频转写失败：\(error.localizedDescription)") }
            }
        }
    }

    func cancelFinalization() {
        stopTimedOut = true
        guard let current = analyzer else { return }
        Task { await current.cancelAndFinishNow() }
    }

    func stop() async {
        stopRequested = true
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        fileTask?.cancel(); fileTask = nil
        engine?.stop()
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0); tapInstalled = false }
        engine = nil
        if let sink { drain = await sink.finish() }
        if let analyzer {
            // Ensure a stalled recognizer cannot leave the Stop button stuck forever.
            let watchdog = Task {
                do { try await Task.sleep(for: .seconds(12)) } catch { return }
                self.stopTimedOut = true
                await analyzer.cancelAndFinishNow()
            }
            do { try await analyzer.finalizeAndFinishThroughEndOfInput() }
            catch { await analyzer.cancelAndFinishNow() }
            watchdog.cancel()
        }
        if let resultsTask { await resultsTask.value }
        resultsTask = nil; sink = nil; analyzer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
