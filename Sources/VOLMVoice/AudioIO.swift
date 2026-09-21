import AVFoundation
import Speech

/// One engine for the mic and for Mónica's voice, so Apple's voice processing can cancel her own
/// voice from what the mic hears.
final class AudioIO {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let playerFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
    private(set) var voiceProcessing = false

    /// Called on the audio thread.
    var onInput: ((AVAudioPCMBuffer) -> Void)?
    var onInputLevel: ((Double) -> Void)?
    var onOutputLevel: ((Double) -> Void)?

    /// Tries voice processing (echo cancellation) first; some devices refuse it, then plain I/O.
    func start() throws {
        do {
            try configure(voiceProcessing: true)
            try engine.start()
        } catch {
            Log.write("audio with voice processing failed: \(error), retrying without it")
            teardown()
            try configure(voiceProcessing: false)
            try engine.start()
        }
        Log.write("audio running, voiceProcessing=\(voiceProcessing)")
    }

    private func configure(voiceProcessing wantVP: Bool) throws {
        let input = engine.inputNode
        let output = engine.outputNode
        let mixer = engine.mainMixerNode
        if wantVP {
            try input.setVoiceProcessingEnabled(true)
            input.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                enableAdvancedDucking: false, duckingLevel: .min)
        }
        voiceProcessing = wantVP
        engine.attach(player)
        engine.connect(player, to: mixer, format: playerFormat)
        // Voice processing changes the output unit's format; wire the mixer to whatever it wants now.
        engine.connect(mixer, to: output, format: output.inputFormat(forBus: 0))

        let inFormat = input.outputFormat(forBus: 0)
        Log.write("mic format: \(inFormat), output: \(output.inputFormat(forBus: 0)), voiceProcessing=\(wantVP)")
        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
            self?.onInput?(buffer)
            self?.onInputLevel?(AudioIO.decibels(buffer))
        }
        player.installTap(onBus: 0, bufferSize: 1024, format: playerFormat) { [weak self] buffer, _ in
            self?.onOutputLevel?(AudioIO.decibels(buffer))
        }
        engine.prepare()
    }

    private func teardown() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        player.removeTap(onBus: 0)
        if engine.attachedNodes.contains(player) { engine.detach(player) }
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        engine.reset()
    }

    static func decibels(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return -100 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        let ch = data[0]
        for i in 0..<n { sum += ch[i] * ch[i] }
        let rms = sqrt(sum / Float(n))
        return Double(20 * log10(max(rms, 1e-7)))
    }

    /// Maps decibels to the 0…1 level the orb uses.
    static func level(_ db: Double) -> Double {
        min(1, max(0, (db + 55) / 40))
    }
}

/// Streams mic audio into Apple's on-device SpeechAnalyzer and reports phrases on its own timeline.
final class Transcriber {
    /// Seconds on the analyzer timeline (0 = first sample fed). Called off the main thread.
    var onSegment: ((_ start: Double, _ end: Double, _ text: String, _ isFinal: Bool) -> Void)?

    private let lock = NSLock()
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzer: SpeechAnalyzer?
    private var module: SpeechTranscriber?
    private var targetFormat: AVAudioFormat?
    private var monoFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private(set) var startUptime: Double?

    func start(locale: Locale) async throws {
        let module = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            Log.write("downloading speech assets for \(locale.identifier)")
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw NSError(domain: "VOLMVoice", code: 1, userInfo: [NSLocalizedDescriptionKey: "no audio format for \(locale.identifier)"])
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        let analyzer = SpeechAnalyzer(modules: [module])
        try await analyzer.prepareToAnalyze(in: format)
        lock.withLock {
            self.module = module
            self.analyzer = analyzer
            self.targetFormat = format
            self.continuation = continuation
        }
        Log.write("transcriber ready: \(format)")
        Task.detached { [weak self] in
            do {
                for try await result in module.results {
                    let text = String(result.text.characters)
                    let start = result.range.start.seconds
                    let end = CMTimeRangeGetEnd(result.range).seconds
                    self?.onSegment?(start, end, text, result.isFinal)
                }
            } catch {
                Log.write("transcriber results ended: \(error)")
            }
        }
        try await analyzer.start(inputSequence: stream)
    }

    /// Audio thread.
    func feed(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let continuation, let target = targetFormat, let src = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let rate = buffer.format.sampleRate
        if monoFormat?.sampleRate != rate {
            monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)
            converter = AVAudioConverter(from: monoFormat!, to: target)
        }
        guard let monoFormat, let converter, let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength) else { return }
        mono.frameLength = buffer.frameLength
        memcpy(mono.floatChannelData![0], src[0], Int(buffer.frameLength) * MemoryLayout<Float>.size)

        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / rate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return mono
        }
        guard error == nil, out.frameLength > 0 else { return }
        if startUptime == nil { startUptime = ProcessInfo.processInfo.systemUptime }
        continuation.yield(AnalyzerInput(buffer: out))
    }
}
