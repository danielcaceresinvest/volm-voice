// siri-speak: persistent speech daemon for VOLM Voice.
//
// Runs under the Apple-signed `swift` interpreter because only Apple-signed processes can see the
// Siri voices; a binary we compile ourselves falls back to the robotic compact voices.
//
// stdin  (one JSON object per line): {"cmd":"speak","id":1,"text":"…"} | {"cmd":"stop"}
// stdout (one JSON object per line): {"ev":"ready","voice":"…"} | {"ev":"pcm","id":1,"sr":48000,"data":"<base64 Float32 mono>"}
//                                    {"ev":"end","id":1} | {"ev":"warn","msg":"…"}
import AVFoundation
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

func emit(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object), let line = String(data: data, encoding: .utf8) else { return }
    print(line)
    fflush(stdout)
}

let voiceId = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "com.apple.siri.natural.Luisa"
var voice: AVSpeechSynthesisVoice?
for _ in 0..<80 {
    voice = AVSpeechSynthesisVoice.speechVoices().first { $0.identifier == voiceId }
    if voice != nil { break }
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
}
if voice == nil {
    emit(["ev": "warn", "msg": "voice \(voiceId) not found, using es-ES default"])
    voice = AVSpeechSynthesisVoice(language: "es-ES")
}

let synth = AVSpeechSynthesizer()
var queue: [(id: Int, text: String)] = []
var busy = false
var generation = 0

func floatSamples(_ pcm: AVAudioPCMBuffer) -> [Float] {
    let n = Int(pcm.frameLength)
    if let f = pcm.floatChannelData { return Array(UnsafeBufferPointer(start: f[0], count: n)) }
    if let i = pcm.int16ChannelData { return UnsafeBufferPointer(start: i[0], count: n).map { Float($0) / 32768 } }
    if let i = pcm.int32ChannelData { return UnsafeBufferPointer(start: i[0], count: n).map { Float($0) / 2147483648 } }
    return []
}

func next() {
    guard !busy, !queue.isEmpty else { return }
    let item = queue.removeFirst()
    busy = true
    let gen = generation
    let utterance = AVSpeechUtterance(string: item.text)
    utterance.voice = voice
    synth.write(utterance) { buffer in
        guard gen == generation else { return }
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        if pcm.frameLength == 0 {
            emit(["ev": "end", "id": item.id])
            busy = false
            DispatchQueue.main.async { next() }
            return
        }
        let samples = floatSamples(pcm)
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        emit(["ev": "pcm", "id": item.id, "sr": pcm.format.sampleRate, "data": data.base64EncodedString()])
    }
}

func handle(_ line: String) {
    guard let data = line.data(using: .utf8),
          let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let cmd = msg["cmd"] as? String else { return }
    switch cmd {
    case "speak":
        guard let id = msg["id"] as? Int, let text = msg["text"] as? String else { return }
        queue.append((id, text))
        next()
    case "stop":
        generation += 1
        queue.removeAll()
        synth.stopSpeaking(at: .immediate)
        busy = false
    default:
        break
    }
}

DispatchQueue.global().async {
    while let line = readLine() {
        DispatchQueue.main.async { handle(line) }
    }
    exit(0)
}

emit(["ev": "ready", "voice": voice?.identifier ?? ""])
RunLoop.main.run()
