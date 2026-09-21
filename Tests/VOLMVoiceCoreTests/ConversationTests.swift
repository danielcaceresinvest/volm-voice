import Foundation
import Testing
@testable import VOLMVoiceCore

final class FakeEffects: ConversationEffects {
    var prompts: [String] = []
    var cancels = 0
    var spoken: [String] = []
    var stops = 0
    var states: [VoiceState] = []
    var lastSubtitles = Subtitles()
    var lastProgress = 0.0

    func sendPrompt(_ text: String) { prompts.append(text) }
    func cancelPrompt() { cancels += 1 }
    func speak(_ sentence: String) { spoken.append(sentence) }
    func stopSpeaking() { stops += 1 }
    func conversationChanged(state: VoiceState, subtitles: Subtitles, followUpProgress: Double) {
        if states.last != state { states.append(state) }
        lastSubtitles = subtitles
        lastProgress = followUpProgress
    }
    func log(_ message: String) {}
}

/// Drives the controller like the app does: 20 ms audio frames, transcript segments on the same clock.
final class Harness {
    let controller = ConversationController()
    let fx = FakeEffects()
    var t = 0.0

    init() {
        controller.effects = fx
        controller.bridgeChanged(up: true, at: 0)
        silence(1)
    }

    func silence(_ seconds: Double) { audio(db: -65, seconds) }
    func voice(_ seconds: Double) { audio(db: -22, seconds) }

    func audio(db: Double, _ seconds: Double) {
        let end = t + seconds
        while t < end {
            t += 0.02
            controller.audioLevel(db: db, at: t)
        }
    }

    /// The user says `text` for `seconds`, with a volatile result midway and a final one at the end.
    func say(_ text: String, _ seconds: Double = 1.2) {
        let start = t
        voice(seconds / 2)
        controller.transcript(TranscriptSegment(start: start, end: t, text: String(text.prefix(text.count / 2)), isFinal: false), at: t)
        voice(seconds / 2)
        controller.transcript(TranscriptSegment(start: start, end: t, text: text, isFinal: true), at: t)
    }

    /// Mónica answers with `chunks` and plays every sentence.
    func answer(_ chunks: [String]) {
        for c in chunks { controller.agentChunk(c) }
        controller.agentFinished(stopReason: "end_turn", at: t)
        playAll()
    }

    func playAll() {
        var played = 0
        while played < fx.spoken.count {
            controller.sentenceStarted(at: t)
            silence(1)
            controller.sentenceFinished(at: t)
            played += 1
        }
    }
}

@Suite struct ConversationTests {
    @Test func wakeCommandAnswerAndFollowUpTimeout() {
        let h = Harness()
        #expect(h.controller.state == .idle)
        h.say("Mónica, ¿qué tiempo hace en Sevilla?")
        #expect(h.controller.state == .listening)
        h.silence(2)
        #expect(h.fx.prompts == ["¿qué tiempo hace en Sevilla?"])
        #expect(h.controller.state == .thinking)
        h.answer(["En Sevilla hace sol. ", "Unos 33 grados y poca humedad."])
        #expect(h.fx.states.contains(.speaking))
        #expect(h.controller.state == .followUp)
        h.silence(9)
        #expect(h.controller.state == .idle)
    }

    @Test func followUpNeedsNoName() {
        let h = Harness()
        h.say("Mónica, apunta una idea")
        h.silence(2)
        h.answer(["Claro, ¿cuál es la idea?"])
        #expect(h.controller.state == .followUp)
        h.silence(3)
        #expect(h.controller.state == .followUp, "a question keeps the mic open for 15 s")
        h.say("un pódcast sobre diseño")
        #expect(h.controller.state == .listening)
        h.silence(2)
        #expect(h.fx.prompts.last == "un pódcast sobre diseño")
    }

    @Test func nameAloneThenCommandAfterPause() {
        let h = Harness()
        h.say("Mónica", 0.5)
        h.silence(1)
        #expect(h.controller.state == .listening)
        h.say("Mónica, dime la hora")
        h.silence(2)
        #expect(h.fx.prompts == ["dime la hora"])
    }

    @Test func nameAloneTimesOut() {
        let h = Harness()
        h.say("Mónica", 0.5)
        h.silence(8)
        #expect(h.controller.state == .idle)
        #expect(h.fx.prompts.isEmpty)
    }

    @Test func stopWhileSpeakingCancels() {
        let h = Harness()
        h.say("Mónica, cuéntame la historia de Sevilla")
        h.silence(2)
        h.controller.agentChunk("Sevilla fue fundada hace muchísimo tiempo por los tartesios. ")
        h.controller.sentenceStarted(at: h.t)
        #expect(h.controller.state == .speaking)
        h.say("Para", 0.4)
        #expect(h.controller.state == .idle)
        #expect(h.fx.cancels == 1)
        #expect(h.fx.stops >= 1)
    }

    @Test func herOwnVoiceDoesNotInterrupt() {
        let h = Harness()
        h.say("Mónica, preséntate")
        h.silence(2)
        h.controller.agentChunk("Soy Mónica, tu asistente de voz en VOLM Studio. ")
        h.controller.sentenceStarted(at: h.t)
        h.say("soy Mónica tu asistente de voz en volm studio", 1.5)
        #expect(h.controller.state == .speaking)
        #expect(h.fx.cancels == 0)
    }

    @Test func closingWordsEndFollowUp() {
        let h = Harness()
        h.say("Mónica, ¿qué hora es?")
        h.silence(2)
        h.answer(["Son las seis y cuarto."])
        h.say("Gracias, Mónica", 0.6)
        h.silence(0.5)
        #expect(h.controller.state == .idle)
        #expect(h.fx.prompts.count == 1)
    }

    @Test func noisyRoomStillSubmits() {
        let h = Harness()
        h.say("Mónica, ¿qué tiempo hace en Dos Hermanas?")
        h.audio(db: -24, 4)
        #expect(h.fx.prompts == ["¿qué tiempo hace en Dos Hermanas?"], "a stable transcript ends the utterance even when the mic never goes quiet")
    }

    @Test func strayPunctuationDoesNotReopenFollowUp() {
        let h = Harness()
        h.say("Mónica, ¿qué hora es?")
        h.silence(2)
        h.answer(["Son las seis y cuarto."])
        h.controller.transcript(TranscriptSegment(start: h.t + 0.5, end: h.t + 1, text: ".", isFinal: false), at: h.t + 1)
        #expect(h.controller.state == .followUp)
        h.silence(10)
        #expect(h.controller.state == .idle)
    }

    @Test func nameDuringFollowUpIsNotSentAsARequest() {
        let h = Harness()
        h.say("Mónica, ¿qué hora es?")
        h.silence(2)
        h.answer(["Son las seis y cuarto, ¿algo más?"])
        h.say("Mónica.", 0.5)
        h.silence(3)
        #expect(h.fx.prompts.count == 1, "her name alone is not a prompt")
        h.say("Mónica, y mañana qué tiempo hace .")
        h.silence(2)
        #expect(h.fx.prompts.last == "y mañana qué tiempo hace")
    }

    @Test func latePunctuationDoesNotDelayTheRequest() {
        let h = Harness()
        h.say("Mónica, qué tiempo hacen dos hermanas")
        h.silence(1)
        h.controller.transcript(TranscriptSegment(start: h.t - 0.2, end: h.t, text: ".", isFinal: false), at: h.t)
        h.silence(0.7)
        #expect(h.fx.prompts == ["qué tiempo hacen dos hermanas"])
    }

    @Test func toolStatusShowsWhileThinking() {
        let h = Harness()
        h.say("Mónica, ¿qué tiempo hace?")
        h.silence(2)
        h.controller.agentTool(kind: "fetch")
        #expect(h.fx.lastSubtitles.status == "Consultando la web")
    }

    @Test func toolTitleNamesWhatSheIsDoing() {
        let h = Harness()
        h.say("Mónica, ¿tengo correo nuevo?")
        h.silence(2)
        h.controller.agentTool(kind: "execute", title: "mcp__openclaw__exec: command: gog gmail search 'is:unread'")
        #expect(h.fx.lastSubtitles.status == "Con tu correo")
        #expect(h.fx.lastSubtitles.flavor == .mail)
    }

    @Test func cardReachesTheScreenAndNeverTheVoice() {
        let h = Harness()
        h.say("Mónica, crea una reunión mañana a las diez")
        h.silence(2)
        h.answer(["Hecho, te la he puesto mañana a las diez. [[tarjeta: evento | Reunión ", "| Mañana, 10:00]]"])
        #expect(h.fx.spoken == ["Hecho, te la he puesto mañana a las diez."])
        #expect(h.fx.lastSubtitles.card == Card(kind: .event, title: "Reunión", detail: "Mañana, 10:00"))
    }

    @Test func confirmCardWaitsForYes() {
        let h = Harness()
        h.say("Mónica, mándale a Pablo el resumen")
        h.silence(2)
        h.answer(["[[tarjeta: confirmar | Enviar correo a Pablo | Asunto: Resumen]]", "Lo tengo listo para Pablo. ¿Lo envío?"])
        #expect(h.controller.state == .followUp)
        #expect(h.fx.lastSubtitles.status.hasPrefix("¿Lo hago?"))
        h.silence(17)
        #expect(h.controller.state == .followUp, "a confirmation waits 20 s")
        h.say("Sí, envíalo", 0.6)
        #expect(h.fx.lastSubtitles.card?.kind == .confirm, "the card stays while the answer is said")
        h.silence(2)
        #expect(h.fx.prompts.last == "Sí, envíalo")
        #expect(h.fx.lastSubtitles.card == nil)
    }

    @Test func cardButtonSendsTheAnswer() {
        let h = Harness()
        h.say("Mónica, borra el borrador")
        h.silence(2)
        h.answer(["[[tarjeta: confirmar | Borrar borrador]] ¿Lo borro?"])
        h.controller.manualPrompt("No, cancélalo.", at: h.t)
        #expect(h.fx.prompts.last == "No, cancélalo.")
        #expect(h.controller.state == .thinking)
    }

    @Test func announcementSpeaksOnlyWhenFree() {
        let h = Harness()
        #expect(h.controller.announce("He terminado los veinte correos.", at: h.t))
        #expect(h.fx.spoken == ["He terminado los veinte correos."])
        #expect(h.fx.prompts.isEmpty)
        h.playAll()
        #expect(h.controller.state == .followUp)
        h.silence(9)
        h.say("Mónica, cuéntame algo largo")
        h.silence(2)
        #expect(h.controller.announce("Otra cosa.", at: h.t) == false, "never talks over a turn in progress")
    }

    @Test func bridgeDropGoesOfflineAndBack() {
        let h = Harness()
        h.controller.bridgeChanged(up: false, at: h.t)
        #expect(h.controller.state == .offline)
        h.controller.bridgeChanged(up: true, at: h.t)
        #expect(h.controller.state == .idle)
    }
}

@Suite struct ACPTests {
    @Test func decodesRealFrames() {
        let chunk = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"a23","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"En Sevilla h"}}}}"#
        guard case .update(let sid, .agentChunk(let text)) = ACPCodec.decode(Data(chunk.utf8)) else { Issue.record("not a chunk"); return }
        #expect(sid == "a23")
        #expect(text == "En Sevilla h")

        let tool = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"a23","update":{"sessionUpdate":"tool_call","toolCallId":"toolu_1","title":"mcp__openclaw__web_fetch: url: https://wttr.in","status":"in_progress","kind":"fetch"}}}"#
        guard case .update(_, .toolCall(let id, let kind, _)) = ACPCodec.decode(Data(tool.utf8)) else { Issue.record("not a tool call"); return }
        #expect(id == "toolu_1")
        #expect(kind == "fetch")

        let done = #"{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}"#
        guard case .response(let rid, let result, _) = ACPCodec.decode(Data(done.utf8)) else { Issue.record("not a response"); return }
        #expect(rid == 3)
        #expect(result?["stopReason"] as? String == "end_turn")

        let perm = #"{"jsonrpc":"2.0","id":"p1","method":"session/request_permission","params":{"sessionId":"a23","options":[]}}"#
        guard case .request(_, let method, _) = ACPCodec.decode(Data(perm.utf8)) else { Issue.record("not a request"); return }
        #expect(method == "session/request_permission")
    }

    @Test func encodesOneLine() {
        let data = ACPCodec.request(id: 1, method: "initialize", params: ["protocolVersion": 1])
        #expect(data.last == 0x0A)
        #expect(data.filter { $0 == 0x0A }.count == 1)
    }
}
