import Testing
@testable import VOLMVoiceCore

@Suite struct WakeTests {
    let wake = WakeDetector()

    @Test func commandAfterName() {
        #expect(wake.match("Mónica, ¿qué tiempo hace en Sevilla?")?.command == "¿qué tiempo hace en Sevilla?")
        #expect(wake.match("oye Mónica pon música")?.command == "pon música")
        #expect(wake.match("Monica. Dime la hora")?.command == "Dime la hora")
    }

    @Test func nameAloneGivesEmptyCommand() {
        #expect(wake.match("Mónica")?.command == "")
    }

    @Test func textBeforeTheNameIsDropped() {
        #expect(wake.match("bueno pues Mónica apunta leche")?.command == "apunta leche")
    }

    @Test func similarNamesDoNotWake() {
        #expect(wake.match("Verónica, ¿vienes?") == nil)
        #expect(wake.match("la armónica suena bien") == nil)
    }
}

@Suite struct IntentTests {
    @Test func stopAndClose() {
        #expect(IntentDetector.intent(of: "Para.") == .stop)
        #expect(IntentDetector.intent(of: "Mónica, cállate") == .stop)
        #expect(IntentDetector.intent(of: "Gracias, Mónica") == .close)
        #expect(IntentDetector.intent(of: "nada más") == .close)
    }

    @Test func longerPhrasesAreNotCommands() {
        #expect(IntentDetector.intent(of: "para mañana a las nueve") == .none)
        #expect(IntentDetector.intent(of: "gracias por el resumen, ahora mándalo") == .none)
    }

    @Test func echoGuard() {
        let spoken = ["En Sevilla hace sol, 33 grados y muy poca humedad."]
        #expect(EchoGuard.isEcho("hace sol 33 grados y muy poca", of: spoken))
        #expect(!EchoGuard.isEcho("y mañana va a llover", of: spoken))
    }
}

@Suite struct SplitterTests {
    @Test func streamsSentencesAsTheyComplete() {
        var s = SentenceSplitter()
        #expect(s.feed("En Sevilla h").isEmpty)
        #expect(s.feed("ace sol y calor, unos 33°C con muy poca humedad. La máxima d") == ["En Sevilla hace sol y calor, unos 33°C con muy poca humedad."])
        #expect(s.feed("e ronda los 33°C y").isEmpty)
        #expect(s.feed(" la mínima nocturna 19°C.").isEmpty)
        #expect(s.flush() == ["La máxima de ronda los 33°C y la mínima nocturna 19°C."])
    }

    @Test func decimalsDoNotSplit() {
        var s = SentenceSplitter()
        #expect(s.feed("Cuesta 12.50 euros en total, más envío. ") == ["Cuesta 12.50 euros en total, más envío."])
    }

    @Test func shortSentencesMerge() {
        var s = SentenceSplitter()
        #expect(s.feed("Vale. Ya está hecho y guardado. ") == ["Vale. Ya está hecho y guardado."])
    }

    @Test func markdownIsCleaned() {
        var s = SentenceSplitter()
        let out = s.feed("**Tres opciones:**\n- Pan integral\n- Leche\n") + s.flush()
        #expect(out.joined(separator: " ") == "Tres opciones: Pan integral, Leche")
        #expect(SentenceSplitter.clean("Mira [la web](https://volm.studio) y https://x.com/abc ahora") == "Mira la web y ahora")
    }

    @Test func codeIsNotRead() {
        var s = SentenceSplitter()
        let out = s.feed("Aquí tienes el script para copiar:\n```bash\necho hola\n```\nEjecútalo en la terminal.") + s.flush()
        #expect(out == ["Aquí tienes el script para copiar:", SentenceSplitter.codeNotice, "Ejecútalo en la terminal."])
    }
}

@Suite struct TranscriptTests {
    @Test func volatileIsReplacedByFinal() {
        var b = TranscriptBuffer()
        b.apply(TranscriptSegment(start: 1, end: 2, text: "Mónica qué", isFinal: false))
        #expect(b.text(since: 0) == "Mónica qué")
        b.apply(TranscriptSegment(start: 1, end: 2.5, text: "Mónica, ¿qué hora es?", isFinal: true))
        #expect(b.text(since: 0) == "Mónica, ¿qué hora es?")
        #expect(b.text(since: 3) == "")
    }

    @Test func vadTracksSpeechAndSilence() {
        var v = VoiceActivity()
        for i in 0..<50 { v.feed(db: -60, at: Double(i) * 0.02) }
        v.feed(db: -25, at: 1.0)
        #expect(v.isSpeaking)
        for i in 1...40 { v.feed(db: -60, at: 1.0 + Double(i) * 0.05) }
        #expect(!v.isSpeaking)
        #expect(v.silence(at: 3.0) > 1.9)
    }
}

@Suite struct DirectiveTests {
    @Test func splitAcrossChunks() {
        var f = DirectiveFilter()
        var text = "", cards: [Card] = []
        for chunk in ["Aquí lo tienes. [", "[tarjeta: correo | Para: Pa", "blo | Asunto: Hola | Te escribo por…]", "] ¿Lo envío?"] {
            let r = f.feed(chunk)
            text += r.text
            cards += r.cards
        }
        let r = f.flush()
        text += r.text
        #expect(text == "Aquí lo tienes.  ¿Lo envío?")
        #expect(cards == [Card(kind: .mail, title: "Para: Pablo", detail: "Asunto: Hola · Te escribo por…")])
    }

    @Test func ordinaryBracketsAreKept() {
        var f = DirectiveFilter()
        let a = f.feed("Mira [esto] y [[esto otro]] también [")
        let b = f.flush()
        #expect(a.text + b.text == "Mira [esto] y [[esto otro]] también [")
        #expect(a.cards.isEmpty && b.cards.isEmpty)
    }

    @Test func unclosedDirectiveIsReleasedAtTheEnd() {
        var f = DirectiveFilter()
        let a = f.feed("Vale [[tarjeta: nota | Sin cerrar")
        let b = f.flush()
        #expect(a.text == "Vale ")
        #expect(b.text == "[[tarjeta: nota | Sin cerrar")
    }

    @Test func flavors() {
        #expect(ToolFlavor.classify(kind: "other", title: "mcp__openclaw__computer: action: screenshot") == .screen)
        #expect(ToolFlavor.classify(kind: "execute", title: "Bash: command: osascript -e 'tell application \"Music\" to play'") == .music)
        #expect(ToolFlavor.classify(kind: "fetch", title: "mcp__openclaw__web_fetch: url: https://wttr.in/Sevilla") == .web)
        #expect(ToolFlavor.classify(kind: "execute", title: "Bash: command: gog calendar events --today") == .calendar)
        #expect(ToolFlavor.classify(kind: nil, title: nil) == nil)
    }
}
