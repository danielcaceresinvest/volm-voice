import AppKit
import AVFoundation
import ServiceManagement
import Speech
import SwiftUI
import VOLMVoiceCore

/// Wires audio, recognition, OpenClaw and the voice together around the conversation controller.
@MainActor
final class AppModel: ObservableObject, @preconcurrency ConversationEffects {
    static let shared = AppModel()

    @Published private(set) var stateLabel = "Conectando"
    @Published var wakeEnabled: Bool { didSet { if prefs.wakeEnabled != wakeEnabled { prefs.wakeEnabled = wakeEnabled } } }
    @Published var pushToTalk: Bool { didSet { if prefs.pushToTalk != pushToTalk { prefs.pushToTalk = pushToTalk }; updateHotkey() } }
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @Published private(set) var stageOpen = false
    /// Everything in `config.json`. Changes are saved and applied as they happen.
    @Published var prefs = Settings.load() { didSet { prefs.save(); applyPrefs() } }

    private var settings: Settings { prefs }
    private let controller = ConversationController()
    private let audio = AudioIO()
    private let transcriber = Transcriber()
    private lazy var speech = SpeechOut(audio: audio)
    private lazy var bridge = OpenClawBridge(sessionKey: settings.sessionKey)
    private let orb = OrbModel()
    private let islandModel = IslandViewModel()
    private var island: IslandController?
    private var ticker: Timer?
    private var currentPrompt: Int?
    private var hotkeyTimer: Timer?
    private var rightOptionSince: Double?
    private var rightOptionDown = false
    private var lastState: VoiceState = .offline
    private var lastVolatileLogged = ""
    private var signalSources: [DispatchSourceSignal] = []
    private var briefingTimer: Timer?
    private let settingsWindow = SettingsWindowController()
    private lazy var stage: StageController = {
        let stage = StageController { [unowned self] in
            StageView(vm: self.islandModel, orb: self.orb, onTap: { [weak self] in self?.orbTapped() }, onAnswer: { [weak self] in self?.answerCard($0) })
        }
        stage.onClose = { [weak self] in self?.stageOpen = false }
        return stage
    }()

    private init() {
        wakeEnabled = true
        pushToTalk = false
        wakeEnabled = settings.wakeEnabled
        pushToTalk = settings.pushToTalk
    }

    private var now: Double { ProcessInfo.processInfo.systemUptime }

    func start() {
        Log.write("--- VOLM Voice start")
        Fonts.register()
        applyPrefs()
        controller.effects = self

        island = IslandController(vm: islandModel, orb: orb, onTap: { [weak self] in self?.orbTapped() }, onAnswer: { [weak self] in self?.answerCard($0) })
        installDebugSignals()
        if CommandLine.arguments.contains("--stage") { toggleStage() }
        if CommandLine.arguments.contains("--demo") {
            startDemo()
            return
        }

        bridge.onUp = { [weak self] in guard let self else { return }; self.controller.bridgeChanged(up: true, at: self.now) }
        bridge.onDown = { [weak self] in guard let self else { return }; self.controller.bridgeChanged(up: false, at: self.now) }
        bridge.onUpdate = { [weak self] update in self?.handle(update) }
        bridge.onPromptDone = { [weak self] id, reason in
            guard let self, id == self.currentPrompt else { return }
            self.currentPrompt = nil
            self.controller.agentFinished(stopReason: reason, at: self.now)
        }
        bridge.onPromptError = { [weak self] id, message in
            guard let self, id == self.currentPrompt else { return }
            self.currentPrompt = nil
            self.controller.agentFailed(message, at: self.now)
        }

        speech.onSentenceStarted = { [weak self] in guard let self else { return }; self.controller.sentenceStarted(at: self.now) }
        speech.onSentenceFinished = { [weak self] in guard let self else { return }; self.controller.sentenceFinished(at: self.now) }
        if let script = Bundle.main.url(forResource: "siri-speak", withExtension: "swift") {
            speech.start(script: script, voiceId: settings.voiceId)
        } else {
            Log.write("siri-speak.swift missing from bundle")
        }

        bridge.start()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; self.controller.tick(at: self.now) }
        }
        updateHotkey()
        briefingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkBriefing() }
        }
        Task { await startListening() }
    }

    private func applyPrefs() {
        orb.viscosity = Float(prefs.viscosity)
        orb.turbulence = Float(prefs.turbulence)
        orb.reaction = prefs.reaction
        orb.cut = prefs.cut
        var config = ConversationConfig()
        config.followUpSeconds = prefs.followUpSeconds
        config.followUpQuestionSeconds = prefs.followUpQuestionSeconds
        config.confirmSeconds = prefs.confirmSeconds
        config.endOfUtteranceSilence = prefs.endOfUtteranceSilence
        controller.config = config
        controller.wake = WakeDetector(wakeWords: prefs.wakeWords)
    }

    func shutdown() {
        speech.shutdown()
        bridge.shutdown()
    }

    /// `kill -USR1 <pid>` starts listening as if the menu item was chosen; `kill -USR2 <pid>` logs the island window.
    private func installDebugSignals() {
        for (sig, action) in [(SIGUSR1, { [weak self] in self?.talkNow() }), (SIGUSR2, { [weak self] in self?.island?.logDiagnostics() })] as [(Int32, () -> Void)] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { action() } }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: - Demo

    /// `--demo`: cycles the island through every state with canned text. No mic, no OpenClaw.
    private func startDemo() {
        Log.write("demo mode")
        let you = "mónica, ¿qué tiempo hace en sevilla?"
        let her = "En Sevilla hace sol, 33 grados y muy poca humedad. La mínima de esta noche ronda los 19."
        let began = now
        ticker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let t = (self.now - began).truncatingRemainder(dividingBy: 22)
                let wobble = 0.5 + 0.5 * sin(self.now * 9) * sin(self.now * 3.7)
                self.orb.inputLevel = wobble
                self.orb.outputLevel = wobble
                switch t {
                case ..<2.5:
                    self.conversationChanged(state: .idle, subtitles: Subtitles(status: "Di «Mónica»"), followUpProgress: 0)
                case ..<5.5:
                    let shown = String(you.prefix(Int((t - 2.5) * 14)))
                    self.conversationChanged(state: .listening, subtitles: Subtitles(you: shown, status: "Escuchando"), followUpProgress: 0)
                case ..<7.5:
                    self.conversationChanged(state: .thinking, subtitles: Subtitles(you: you, status: "Consultando la web"), followUpProgress: 0)
                case ..<12:
                    let words = her.split(separator: " ")
                    let shown = words.prefix(1 + Int((t - 7.5) * 4)).joined(separator: " ")
                    self.conversationChanged(state: .speaking, subtitles: Subtitles(you: you, her: shown, status: "Hablando"), followUpProgress: 0)
                case ..<16:
                    let left = 16 - t
                    self.conversationChanged(state: .followUp, subtitles: Subtitles(her: her, status: "Te escucho · \(Int(left.rounded(.up))) s"), followUpProgress: left / 4)
                case ..<18:
                    self.conversationChanged(state: .thinking, subtitles: Subtitles(you: "mándale a Pablo el resumen de hoy", status: "Con tu correo", flavor: .mail), followUpProgress: 0)
                default:
                    let left = 22 - t
                    let card = Card(kind: .confirm, title: "Enviar correo a Pablo", detail: "Asunto: Resumen de hoy · Hola Pablo, te paso lo que hemos visto…")
                    self.conversationChanged(state: .followUp, subtitles: Subtitles(her: "Lo tengo listo para Pablo. ¿Lo envío?", status: "¿Lo hago? · \(Int(left.rounded(.up))) s", card: card), followUpProgress: left / 4)
                }
            }
        }
    }

    // MARK: - Mic and recognition

    private func startListening() async {
        let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
        guard micGranted else {
            Log.write("microphone permission denied")
            islandModel.subtitles = Subtitles(status: "Sin permiso de micrófono")
            return
        }
        let speechStatus = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        Log.write("speech authorization: \(speechStatus.rawValue)")

        let transcriber = self.transcriber
        transcriber.onSegment = { [weak self] start, end, text, isFinal in
            DispatchQueue.main.async { self?.handleSegment(start: start, end: end, text: text, isFinal: isFinal) }
        }
        do {
            try await transcriber.start(locale: Locale(identifier: settings.locale))
        } catch {
            Log.write("transcriber failed: \(error)")
            islandModel.subtitles = Subtitles(status: "Reconocimiento de voz no disponible")
            return
        }
        audio.onInput = { buffer in transcriber.feed(buffer) }
        audio.onInputLevel = { [weak self] db in
            DispatchQueue.main.async { self?.handleInputLevel(db) }
        }
        audio.onOutputLevel = { [weak self] db in
            DispatchQueue.main.async { self?.orb.outputLevel = AudioIO.level(db) }
        }
        do {
            try audio.start()
            Log.write("audio started")
        } catch {
            Log.write("audio failed: \(error)")
            islandModel.subtitles = Subtitles(status: "No puedo usar el micrófono")
        }
    }

    private func handleInputLevel(_ db: Double) {
        orb.inputLevel = AudioIO.level(db)
        controller.audioLevel(db: db, at: now)
    }

    private func handleSegment(start: Double, end: Double, text: String, isFinal: Bool) {
        guard let origin = transcriber.startUptime else { return }
        if !wakeEnabled, controller.state == .idle { return }
        let segment = TranscriptSegment(start: origin + start, end: origin + end, text: text, isFinal: isFinal)
        let lag = now - segment.end
        if isFinal || text != lastVolatileLogged {
            Log.write(String(format: "%@ [%.1f-%.1f lag %.1fs] %@", isFinal ? "final" : "vol", segment.start - origin, segment.end - origin, lag, text))
            lastVolatileLogged = isFinal ? "" : text
        }
        controller.transcript(segment, at: now)
    }

    private func handle(_ update: ACPUpdate) {
        switch update {
        case .agentChunk(let text): controller.agentChunk(text)
        case .toolCall(_, let kind, let title):
            Log.write("tool: \(kind ?? "-") \(title ?? "")")
            controller.agentTool(kind: kind, title: title)
        default: break
        }
    }

    // MARK: - User actions

    func talkNow() { controller.manualListen(at: now) }
    func stopNow() { controller.manualStop(at: now) }
    func reconnect() { bridge.restart() }

    private func orbTapped() {
        switch controller.state {
        case .idle: controller.manualListen(at: now)
        case .listening: controller.manualRelease(at: now)
        case .thinking, .speaking, .followUp: controller.manualStop(at: now)
        case .offline: bridge.restart()
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.write("login item: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func openLog() { NSWorkspace.shared.open(Log.url) }
    func openSettings() { settingsWindow.show(model: self) }

    /// The ✓ and ✕ under a "¿lo hago?" card. Saying it works too.
    private func answerCard(_ yes: Bool) {
        controller.manualPrompt(yes ? "Sí, hazlo." : "No, no lo hagas.", at: now)
    }

    func toggleStage() {
        if stage.isOpen { stage.close() } else { stage.show() }
        stageOpen = stage.isOpen
    }

    func shiftBriefing(minutes: Int) {
        let total = ((prefs.briefingHour * 60 + prefs.briefingMinute + minutes) % 1440 + 1440) % 1440
        prefs.briefingHour = total / 60
        prefs.briefingMinute = total % 60
    }

    /// Says the morning summary once a day, at the set time or up to two hours later if the Mac was busy or asleep.
    private func checkBriefing() {
        guard prefs.briefingEnabled, controller.state == .idle else { return }
        let calendar = Calendar.current
        let date = Date()
        let minutes = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        let due = prefs.briefingHour * 60 + prefs.briefingMinute
        guard minutes >= due, minutes < due + 120 else { return }
        let today = calendar.startOfDay(for: date).timeIntervalSince1970
        guard UserDefaults.standard.double(forKey: "lastBriefingDay") != today else { return }
        UserDefaults.standard.set(today, forKey: "lastBriefingDay")
        Log.write("briefing")
        controller.manualPrompt(prefs.briefingPrompt, at: now)
    }

    // MARK: - Links

    /// `volm-voice://listen`, `stop`, `ask?key=…&q=…` and `say?key=…&text=…`. The last two act on
    /// outside text, so they need the secret from `config.json`; a link on a web page does not have it.
    func open(_ url: URL) {
        guard url.scheme == "volm-voice", let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let action = url.host ?? ""
        func value(_ name: String) -> String { parts.queryItems?.first { $0.name == name }?.value ?? "" }
        switch action {
        case "listen": talkNow()
        case "stop": stopNow()
        case "stage": toggleStage()
        case "ask", "say":
            guard !prefs.urlKey.isEmpty, value("key") == prefs.urlKey else {
                Log.write("link \(action) refused: wrong key")
                return
            }
            let text = value(action == "ask" ? "q" : "text").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= 2000 else { return }
            Log.write("link \(action): \(text)")
            if action == "ask" {
                controller.manualPrompt(text, at: now)
            } else if !controller.announce(text, at: now) {
                pendingAnnouncements.append(text)
            }
        default: Log.write("link: unknown action \(action)")
        }
    }

    /// Announcements that arrived mid-conversation wait for the next quiet moment.
    private var pendingAnnouncements: [String] = []

    private func flushAnnouncements() {
        guard controller.state == .idle, let next = pendingAnnouncements.first else { return }
        if controller.announce(next, at: now) { pendingAnnouncements.removeFirst() }
    }

    /// Hold the right Option key to talk. The key is polled rather than monitored: a global
    /// NSEvent monitor makes macOS drop the island panel from the active Space (it never renders),
    /// and polling needs no Accessibility or Input Monitoring permission.
    private func updateHotkey() {
        hotkeyTimer?.invalidate()
        hotkeyTimer = nil
        rightOptionSince = nil
        guard pushToTalk else { return }
        hotkeyTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollRightOption() }
        }
    }

    private func pollRightOption() {
        let down = CGEventSource.keyState(.combinedSessionState, key: 61)
        let t = now
        if down {
            if rightOptionSince == nil { rightOptionSince = t }
            // A short tap is ordinary typing (⌥ plus a letter); only a deliberate hold talks.
            if !rightOptionDown, t - (rightOptionSince ?? t) >= 0.3 { rightOption(down: true) }
        } else {
            rightOptionSince = nil
            if rightOptionDown { rightOption(down: false) }
        }
    }

    private func rightOption(down: Bool) {
        guard down != rightOptionDown else { return }
        rightOptionDown = down
        if down { controller.manualListen(at: now) } else { controller.manualRelease(at: now) }
    }

    // MARK: - ConversationEffects

    func sendPrompt(_ text: String) {
        currentPrompt = bridge.prompt(text)
        if currentPrompt == nil { controller.agentFailed("sin conexión", at: now) }
    }

    func cancelPrompt() {
        bridge.cancel()
        currentPrompt = nil
    }

    func speak(_ sentence: String) { speech.speak(sentence) }
    func stopSpeaking() { speech.stop() }

    func conversationChanged(state: VoiceState, subtitles: Subtitles, followUpProgress: Double) {
        if state != lastState {
            if state == .listening, lastState == .idle { NSSound(named: "Tink")?.play() }
            lastState = state
            if state == .idle, !pendingAnnouncements.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.flushAnnouncements() }
            }
        }
        orb.mode = state
        orb.ring = followUpProgress
        if islandModel.state != state { islandModel.state = state }
        if islandModel.subtitles != subtitles { islandModel.subtitles = subtitles }
        let label: String
        switch state {
        case .idle: label = wakeEnabled ? "Esperando «Mónica»" : "En pausa"
        case .listening: label = "Escuchando"
        case .thinking: label = "Pensando"
        case .speaking: label = "Hablando"
        case .followUp: label = "Te escucho"
        case .offline: label = "Sin conexión con OpenClaw"
        }
        if stateLabel != label { stateLabel = label }
    }

    func log(_ message: String) { Log.write(message) }
}
