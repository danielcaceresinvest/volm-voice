import Foundation

public enum VoiceState: String, Equatable {
    case idle, listening, thinking, speaking, followUp, offline
}

public struct Subtitles: Equatable {
    public var you: String
    public var her: String
    public var status: String
    /// What Mónica put on screen for this turn, if anything.
    public var card: Card?
    /// What the running tool is about; drives the colour of the status dot.
    public var flavor: ToolFlavor?

    public init(you: String = "", her: String = "", status: String = "", card: Card? = nil, flavor: ToolFlavor? = nil) {
        self.you = you
        self.her = her
        self.status = status
        self.card = card
        self.flavor = flavor
    }
}

/// Side effects the controller asks the app to perform. All calls happen on the caller's thread.
public protocol ConversationEffects: AnyObject {
    func sendPrompt(_ text: String)
    func cancelPrompt()
    func speak(_ sentence: String)
    func stopSpeaking()
    func conversationChanged(state: VoiceState, subtitles: Subtitles, followUpProgress: Double)
    func log(_ message: String)
}

public struct ConversationConfig {
    public var followUpSeconds: Double = 8
    public var followUpQuestionSeconds: Double = 15
    /// How long a "¿lo hago?" waits for a yes or a no.
    public var confirmSeconds: Double = 20
    public var endOfUtteranceSilence: Double = 1.5
    public var noCommandTimeout: Double = 6
    public var maxUtterance: Double = 40

    public init() {}
}

/// The voice conversation as a state machine. It owns no audio and no network: the app feeds it
/// levels, transcript segments and agent events on one clock (seconds), and it answers with effects.
public final class ConversationController {
    public private(set) var state: VoiceState = .offline
    public private(set) var subtitles = Subtitles(status: "Conectando")
    public weak var effects: ConversationEffects?
    public var config: ConversationConfig
    public var wake: WakeDetector

    private var transcript = TranscriptBuffer()
    private var vad = VoiceActivity()
    private var now: Double = 0
    private var mark: Double = 0
    private var stateSince: Double = 0
    private var requireWake = true
    private var followUpUntil: Double = 0
    private var followUpLength: Double = 8

    private var splitter = SentenceSplitter()
    private var directives = DirectiveFilter()
    private var sentences: [String] = []
    private var sentencesStarted = 0
    private var sentencesFinished = 0
    private var agentDone = true
    private var lastSpoken: [String] = []
    /// Audio before this time already produced a prompt (or was dismissed); late results for it are ignored.
    private var consumedUntil: Double = 0
    /// Last time the recognized text changed. A stable transcript is the main end-of-utterance signal;
    /// mic energy alone is fooled by background noise.
    private var lastTextChange: Double = 0
    private var lastHeardText = ""

    public init(config: ConversationConfig = ConversationConfig(), wake: WakeDetector = WakeDetector()) {
        self.config = config
        self.wake = wake
    }

    // MARK: - Inputs

    public func bridgeChanged(up: Bool, at t: Double) {
        now = t
        if up {
            if state == .offline {
                effects?.log("bridge up")
                enter(.idle, at: t)
            }
        } else if state != .offline {
            effects?.log("bridge down")
            if !agentDone { agentDone = true }
            effects?.stopSpeaking()
            enter(.offline, at: t)
        }
    }

    public func audioLevel(db: Double, at t: Double) {
        vad.feed(db: db, at: t)
        tick(at: t)
    }

    public func transcript(_ segment: TranscriptSegment, at t: Double) {
        transcript.apply(segment)
        // Punctuation the recognizer adds or moves after the fact is not new speech.
        let heardNow = VoiceText.normalize(transcript.text(since: mark))
        if heardNow != lastHeardText {
            lastHeardText = heardNow
            lastTextChange = t
        }
        if segment.isFinal { effects?.log("heard: \(segment.text)") }
        evaluateTranscript(latest: segment, at: t)
    }

    public func tick(at t: Double) {
        now = t
        switch state {
        case .idle:
            if vad.silence(at: t) > 3, t - mark > 3 {
                mark = t - 0.5
                transcript.prune(before: t - 30)
            }
        case .listening:
            let command = currentCommand()
            let silence = vad.silence(at: t)
            let waited = t - stateSince
            let textQuiet = t - lastTextChange
            let pause = config.endOfUtteranceSilence
            let done = textQuiet >= pause && (silence >= pause || textQuiet >= pause * 2)
            if !command.isEmpty, done, waited > 0.6 {
                submit(command, at: t)
            } else if command.isEmpty, waited > config.noCommandTimeout, textQuiet > 2 {
                effects?.log("no command heard")
                enter(.idle, at: t)
            } else if waited > config.maxUtterance, !command.isEmpty {
                submit(command, at: t)
            } else {
                publish()
            }
        case .followUp:
            if t >= followUpUntil, t - lastTextChange > 1.5 {
                enter(.idle, at: t)
            } else {
                publish()
            }
        default:
            break
        }
    }

    /// Menu, hotkey or a click on the orb: listen now, no wake word needed.
    public func manualListen(at t: Double) {
        now = t
        if state == .offline { return }
        if state == .thinking || state == .speaking { interrupt() }
        startListening(requireWake: false, mark: t, at: t)
    }

    /// Push-to-talk released: send what was said so far.
    public func manualRelease(at t: Double) {
        now = t
        guard state == .listening else { return }
        let command = currentCommand()
        if command.isEmpty { enter(.idle, at: t) } else { submit(command, at: t) }
    }

    /// Click on the orb while she works or talks, or the menu's stop item.
    public func manualStop(at t: Double) {
        now = t
        if state == .offline { return }
        interrupt()
        enter(.idle, at: t)
    }

    public func agentChunk(_ text: String) {
        guard state == .thinking || state == .speaking, !agentDone else { return }
        let parsed = directives.feed(text)
        show(parsed.cards)
        for sentence in splitter.feed(parsed.text) { queue(sentence) }
    }

    public func agentTool(kind: String?, title: String? = nil) {
        guard state == .thinking, !agentDone else { return }
        let flavor = ToolFlavor.classify(kind: kind, title: title)
        subtitles.flavor = flavor
        subtitles.status = flavor?.status ?? ACPCodec.status(forToolKind: kind)
        publish()
    }

    /// A request that did not come from the mic: a card button, the Siri shortcut, the daily briefing.
    public func manualPrompt(_ text: String, at t: Double) {
        now = t
        let command = Self.tidy(text)
        guard state != .offline, !command.isEmpty else { return }
        if state == .thinking || state == .speaking { interrupt() }
        submit(command, at: t)
    }

    /// Mónica speaks first, for instance when a background task ends. Never talks over a conversation.
    @discardableResult
    public func announce(_ text: String, at t: Double) -> Bool {
        now = t
        guard state == .idle || state == .followUp else { return false }
        effects?.log("announce: \(text)")
        beginTurn(at: t)
        subtitles = Subtitles(status: "Mónica")
        enter(.thinking, at: t)
        agentChunk(text)
        agentFinished(stopReason: "announce", at: t)
        return true
    }

    public func agentFinished(stopReason: String, at t: Double) {
        now = t
        guard !agentDone else { return }
        let parsed = directives.flush()
        show(parsed.cards)
        for sentence in splitter.feed(parsed.text) { queue(sentence) }
        agentDone = true
        for sentence in splitter.flush() { queue(sentence) }
        effects?.log("agent finished: \(stopReason), \(sentences.count) sentences")
        if sentences.isEmpty {
            enter(.idle, at: t)
        } else if sentencesFinished >= sentences.count {
            finishTurn(at: t)
        }
    }

    public func agentFailed(_ message: String, at t: Double) {
        now = t
        guard !agentDone else { return }
        agentDone = true
        effects?.log("agent failed: \(message)")
        queue("No he podido completarlo. Inténtalo otra vez.")
    }

    public func sentenceStarted(at t: Double) {
        now = t
        guard state == .thinking || state == .speaking else { return }
        sentencesStarted += 1
        if state == .thinking { enter(.speaking, at: t) }
        subtitles.her = sentences.prefix(sentencesStarted).joined(separator: " ")
        publish()
    }

    public func sentenceFinished(at t: Double) {
        now = t
        sentencesFinished += 1
        if agentDone, sentencesFinished >= sentences.count, state == .speaking || state == .thinking {
            finishTurn(at: t)
        }
    }

    // MARK: - Logic

    private func evaluateTranscript(latest segment: TranscriptSegment, at t: Double) {
        let heard = transcript.text(since: mark)
        switch state {
        case .idle:
            if wake.match(heard) != nil, !EchoGuard.isEcho(heard, of: lastSpoken) {
                effects?.log("wake: \(heard)")
                startListening(requireWake: true, mark: mark, at: t)
            } else if segment.isFinal, segment.start >= consumedUntil, segment.end > t - 20,
                      wake.match(segment.text) != nil, !EchoGuard.isEcho(segment.text, of: lastSpoken) {
                // The recognizer can confirm a phrase seconds late; still honour it.
                effects?.log("late wake: \(segment.text)")
                startListening(requireWake: true, mark: segment.start - 0.01, at: t)
            }
        case .listening:
            if IntentDetector.intent(of: currentCommand()) == .stop, !transcript.hasPendingVolatile {
                enter(.idle, at: t)
            } else {
                publish()
            }
        case .thinking, .speaking:
            // Only the newest phrase counts here: older ones may be her own voice leaking into the mic.
            let latest = segment.text
            guard segment.end > mark, !latest.isEmpty, !EchoGuard.isEcho(latest, of: sentences) else { return }
            let intent = IntentDetector.intent(of: latest)
            if intent == .stop || intent == .close {
                effects?.log("barge-in \(intent): \(latest)")
                interrupt()
                enter(.idle, at: t)
            } else if wake.match(latest) != nil {
                effects?.log("barge-in wake: \(latest)")
                interrupt()
                startListening(requireWake: true, mark: segment.start - 0.01, at: t)
            }
        case .followUp:
            guard !VoiceText.words(heard).isEmpty, !EchoGuard.isEcho(heard, of: lastSpoken) else { return }
            switch IntentDetector.intent(of: heard) {
            case .stop, .close:
                if !transcript.hasPendingVolatile { enter(.idle, at: t) }
            case .none:
                effects?.log("follow-up: \(heard)")
                startListening(requireWake: false, mark: mark, at: t)
            }
        case .offline:
            break
        }
    }

    private func currentCommand() -> String {
        let heard = transcript.text(since: mark)
        // Her name is never part of the request, with or without the wake word being required.
        if let match = wake.match(heard) { return Self.tidy(match.command) }
        return requireWake ? "" : Self.tidy(heard)
    }

    /// Drops stray punctuation tokens the recognizer emits on their own ("qué hora es .").
    private static func tidy(_ text: String) -> String {
        text.split(separator: " ").filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }.joined(separator: " ")
    }

    private func startListening(requireWake: Bool, mark: Double, at t: Double) {
        self.requireWake = requireWake
        self.mark = mark
        lastTextChange = t
        // A pending "¿lo hago?" stays on screen while the answer is being said.
        let pending = state == .followUp ? subtitles.card.flatMap { $0.needsAnswer ? $0 : nil } : nil
        subtitles = Subtitles(status: "Escuchando", card: pending)
        enter(.listening, at: t)
    }

    private func submit(_ command: String, at t: Double) {
        let intent = IntentDetector.intent(of: command)
        if intent != .none {
            effects?.log("utterance intent \(intent): \(command)")
            enter(.idle, at: t)
            return
        }
        effects?.log("prompt: \(command)")
        beginTurn(at: t)
        subtitles = Subtitles(you: command, her: "", status: "Pensando")
        enter(.thinking, at: t)
        effects?.sendPrompt(command)
    }

    private func beginTurn(at t: Double) {
        consumedUntil = t
        splitter.reset()
        directives.reset()
        sentences = []
        sentencesStarted = 0
        sentencesFinished = 0
        agentDone = false
        mark = t
    }

    private func show(_ cards: [Card]) {
        guard let card = cards.last else { return }
        effects?.log("card \(card.kind.rawValue): \(card.title)")
        subtitles.card = card
        publish()
    }

    private func queue(_ sentence: String) {
        sentences.append(sentence)
        effects?.speak(sentence)
    }

    private func finishTurn(at t: Double) {
        lastSpoken = sentences
        let asked = sentences.last.map { $0.trimmingCharacters(in: .whitespaces).hasSuffix("?") } ?? false
        followUpLength = asked ? config.followUpQuestionSeconds : config.followUpSeconds
        if subtitles.card?.needsAnswer == true { followUpLength = config.confirmSeconds }
        subtitles.flavor = nil
        followUpUntil = t + followUpLength
        mark = t + 0.3
        subtitles.status = "Te escucho"
        enter(.followUp, at: t)
    }

    private func interrupt() {
        if !agentDone {
            agentDone = true
            effects?.cancelPrompt()
        }
        effects?.stopSpeaking()
        lastSpoken = sentences
    }

    private func enter(_ next: VoiceState, at t: Double) {
        if next != state { effects?.log("state \(state.rawValue) -> \(next.rawValue)") }
        state = next
        stateSince = t
        switch next {
        case .idle:
            if state != .offline { consumedUntil = max(consumedUntil, mark) }
            mark = t
            requireWake = true
            subtitles = Subtitles(status: "Di «Mónica»")
        case .offline:
            subtitles = Subtitles(status: "Sin conexión · reintentando")
        case .speaking:
            subtitles.status = "Hablando"
        default:
            break
        }
        publish()
    }

    private func publish() {
        var shown = subtitles
        var progress = 0.0
        if state == .followUp {
            let left = max(0, followUpUntil - now)
            progress = followUpLength > 0 ? left / followUpLength : 0
            let waiting = subtitles.card?.needsAnswer == true ? "¿Lo hago?" : "Te escucho"
            shown.status = "\(waiting) · \(Int(left.rounded(.up))) s"
        }
        if state == .listening {
            let command = currentCommand()
            shown.you = command
        }
        effects?.conversationChanged(state: state, subtitles: shown, followUpProgress: progress)
    }
}
