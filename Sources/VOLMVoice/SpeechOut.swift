import AVFoundation
import Foundation

/// Mónica's voice: sentences go to the `siri-speak` daemon, its PCM comes back and plays through
/// the shared engine (so echo cancellation knows what she is saying). All methods run on main.
final class SpeechOut {
    var onSentenceStarted: (() -> Void)?
    var onSentenceFinished: (() -> Void)?

    private let audio: AudioIO
    private var process: Process?
    private var stdin: FileHandle?
    private var pending = Data()
    private var script: URL?
    private var voiceId = ""

    private var nextId = 1
    private var generation = 0
    private var idGeneration: [Int: Int] = [:]
    private var queued: [Int] = []
    private var outstanding: [Int: Int] = [:]
    private var started = Set<Int>()
    private var ended = Set<Int>()
    private var converter: AVAudioConverter?
    private var converterRate: Double = 0

    init(audio: AudioIO) {
        self.audio = audio
    }

    func start(script: URL, voiceId: String) {
        self.script = script
        self.voiceId = voiceId
        launch()
    }

    private func launch() {
        guard let script else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        p.arguments = [script.path, voiceId]
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            DispatchQueue.main.async { self?.consume(data) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if !data.isEmpty, let s = String(data: data, encoding: .utf8) { Log.write("siri-speak stderr: \(s.trimmingCharacters(in: .whitespacesAndNewlines))") }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                Log.write("siri-speak exited (\(proc.terminationStatus)), restarting")
                self?.stdin = nil
                self?.resetQueue(notify: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.launch() }
            }
        }
        do {
            try p.run()
            process = p
            stdin = inPipe.fileHandleForWriting
            Log.write("siri-speak launched")
        } catch {
            Log.write("siri-speak failed to launch: \(error)")
        }
    }

    func speak(_ text: String) {
        let id = nextId
        nextId += 1
        idGeneration[id] = generation
        outstanding[id] = 0
        send(["cmd": "speak", "id": id, "text": text])
    }

    func stop() {
        generation += 1
        send(["cmd": "stop"])
        audio.player.stop()
        resetQueue(notify: false)
    }

    func shutdown() {
        process?.terminationHandler = nil
        process?.terminate()
    }

    private func resetQueue(notify: Bool) {
        let unfinished = idGeneration.filter { $0.value == generation }.count
        queued.removeAll()
        outstanding.removeAll()
        started.removeAll()
        ended.removeAll()
        idGeneration.removeAll()
        if notify { for _ in 0..<unfinished { onSentenceFinished?() } }
    }

    private func send(_ object: [String: Any]) {
        guard let stdin, var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        try? stdin.write(contentsOf: data)
    }

    private func consume(_ data: Data) {
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            pending.removeSubrange(pending.startIndex...newline)
            guard let msg = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let ev = msg["ev"] as? String else { continue }
            switch ev {
            case "ready": Log.write("siri-speak ready: \(msg["voice"] ?? "")")
            case "warn": Log.write("siri-speak: \(msg["msg"] ?? "")")
            case "pcm": handlePCM(msg)
            case "end": handleEnd(msg)
            default: break
            }
        }
    }

    private func handlePCM(_ msg: [String: Any]) {
        guard let id = msg["id"] as? Int, idGeneration[id] == generation,
              let rate = msg["sr"] as? Double, let b64 = msg["data"] as? String, let raw = Data(base64Encoded: b64) else { return }
        guard var buffer = makeBuffer(raw, rate: rate) else { return }
        if rate != audio.playerFormat.sampleRate, let converted = convert(buffer, from: rate) { buffer = converted }
        let gen = generation
        let wasEmpty = queued.isEmpty
        queued.append(id)
        outstanding[id, default: 0] += 1
        audio.player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { self?.bufferPlayed(id: id, generation: gen) }
        }
        if !audio.player.isPlaying { audio.player.play() }
        if wasEmpty { markStarted(id) }
    }

    private func handleEnd(_ msg: [String: Any]) {
        guard let id = msg["id"] as? Int, idGeneration[id] == generation else { return }
        ended.insert(id)
        if outstanding[id, default: 0] == 0 {
            if !started.contains(id) { markStarted(id) }
            finish(id)
        }
    }

    private func bufferPlayed(id: Int, generation gen: Int) {
        guard gen == generation, !queued.isEmpty else { return }
        queued.removeFirst()
        outstanding[id, default: 1] -= 1
        if let next = queued.first, !started.contains(next) { markStarted(next) }
        if outstanding[id] == 0, ended.contains(id) { finish(id) }
    }

    private func markStarted(_ id: Int) {
        guard !started.contains(id) else { return }
        started.insert(id)
        onSentenceStarted?()
    }

    private func finish(_ id: Int) {
        idGeneration[id] = nil
        outstanding[id] = nil
        ended.remove(id)
        onSentenceFinished?()
    }

    private func makeBuffer(_ raw: Data, rate: Double) -> AVAudioPCMBuffer? {
        let frames = raw.count / MemoryLayout<Float>.size
        guard frames > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        raw.withUnsafeBytes { ptr in
            memcpy(buffer.floatChannelData![0], ptr.baseAddress!, frames * MemoryLayout<Float>.size)
        }
        return buffer
    }

    private func convert(_ buffer: AVAudioPCMBuffer, from rate: Double) -> AVAudioPCMBuffer? {
        if converter == nil || converterRate != rate {
            converter = AVAudioConverter(from: buffer.format, to: audio.playerFormat)
            converterRate = rate
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * audio.playerFormat.sampleRate / rate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: audio.playerFormat, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil ? out : nil
    }
}
