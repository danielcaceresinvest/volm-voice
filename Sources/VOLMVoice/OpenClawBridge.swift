import Foundation
import VOLMVoiceCore

/// Keeps one `openclaw acp` process alive and speaks ACP with it. All callbacks arrive on main.
final class OpenClawBridge {
    var onUp: (() -> Void)?
    var onDown: (() -> Void)?
    var onUpdate: ((ACPUpdate) -> Void)?
    var onPromptDone: ((_ promptId: Int, _ stopReason: String) -> Void)?
    var onPromptError: ((_ promptId: Int, _ message: String) -> Void)?

    let sessionKey: String
    private(set) var isUp = false
    private var process: Process?
    private var stdin: FileHandle?
    private var pending = Data()
    private var nextId = 1
    private var handlers: [Int: (ACPInbound) -> Void] = [:]
    private var sessionId: String?
    private var activePrompt: Int?
    /// A cancelled prompt whose late updates must be dropped until its response arrives.
    private var cancelledPrompt: Int?
    private var backoff: Double = 1
    private var stopped = false

    init(sessionKey: String) {
        self.sessionKey = sessionKey
    }

    func start() {
        stopped = false
        launch()
    }

    func restart() {
        Log.write("acp restart requested")
        process?.terminate()
    }

    func shutdown() {
        stopped = true
        process?.terminate()
    }

    /// Returns the prompt id, or nil when there is no session yet.
    @discardableResult
    func prompt(_ text: String) -> Int? {
        guard let sessionId, isUp else { return nil }
        let id = request("session/prompt", ACPCodec.textPrompt(sessionId: sessionId, text: text)) { [weak self] inbound in
            guard let self, case .response(let rid, let result, let error) = inbound else { return }
            if self.activePrompt == rid { self.activePrompt = nil }
            if self.cancelledPrompt == rid { self.cancelledPrompt = nil }
            if let error {
                self.onPromptError?(rid, error["message"] as? String ?? "error")
            } else {
                self.onPromptDone?(rid, result?["stopReason"] as? String ?? "end_turn")
            }
        }
        activePrompt = id
        return id
    }

    func cancel() {
        guard let sessionId, let active = activePrompt else { return }
        cancelledPrompt = active
        activePrompt = nil
        write(ACPCodec.notification(method: "session/cancel", params: ["sessionId": sessionId]))
    }

    // MARK: - Process

    private static func executable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for path in ["/opt/homebrew/bin/openclaw", "/usr/local/bin/openclaw", "\(home)/.local/bin/openclaw"] where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private func launch() {
        guard !stopped else { return }
        guard let exe = Self.executable() else {
            Log.write("openclaw not found")
            scheduleRelaunch()
            return
        }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["acp", "--session", sessionKey, "--no-prefix-cwd"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        p.environment = env
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
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
            if !data.isEmpty, let s = String(data: data, encoding: .utf8) { Log.write("acp stderr: \(s.trimmingCharacters(in: .whitespacesAndNewlines))") }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.exited(status: proc.terminationStatus) }
        }
        do {
            try p.run()
        } catch {
            Log.write("acp launch failed: \(error)")
            scheduleRelaunch()
            return
        }
        process = p
        stdin = inPipe.fileHandleForWriting
        Log.write("acp launched (\(sessionKey))")
        request("initialize", ["protocolVersion": 1, "clientCapabilities": [String: Any]()]) { [weak self] _ in
            guard let self else { return }
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            self.request("session/new", ["cwd": home, "mcpServers": [Any]()]) { [weak self] inbound in
                guard let self, case .response(_, let result, let error) = inbound, error == nil,
                      let sid = result?["sessionId"] as? String else {
                    Log.write("acp session/new failed")
                    self?.process?.terminate()
                    return
                }
                self.sessionId = sid
                self.isUp = true
                self.backoff = 1
                Log.write("acp session \(sid)")
                self.onUp?()
            }
        }
    }

    private func exited(status: Int32) {
        Log.write("acp exited (\(status))")
        let wasUp = isUp
        isUp = false
        sessionId = nil
        stdin = nil
        process = nil
        cancelledPrompt = nil
        if let prompt = activePrompt {
            activePrompt = nil
            onPromptError?(prompt, "OpenClaw se ha desconectado")
        }
        handlers.removeAll()
        if wasUp { onDown?() }
        scheduleRelaunch()
    }

    private func scheduleRelaunch() {
        guard !stopped else { return }
        let delay = backoff
        backoff = min(backoff * 2, 30)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.launch() }
    }

    // MARK: - JSON-RPC

    @discardableResult
    private func request(_ method: String, _ params: [String: Any], handler: @escaping (ACPInbound) -> Void) -> Int {
        let id = nextId
        nextId += 1
        handlers[id] = handler
        write(ACPCodec.request(id: id, method: method, params: params))
        return id
    }

    private func write(_ data: Data) {
        try? stdin?.write(contentsOf: data)
    }

    private func consume(_ data: Data) {
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = Data(pending[pending.startIndex..<newline])
            pending.removeSubrange(pending.startIndex...newline)
            guard let inbound = ACPCodec.decode(line) else { continue }
            switch inbound {
            case .response(let id, _, _):
                handlers.removeValue(forKey: id)?(inbound)
            case .update(_, let update):
                if cancelledPrompt == nil { onUpdate?(update) }
            case .request(let id, let method, let params):
                // Tools run directly under the claude-cli runtime, so this should not happen. Never approve silently.
                Log.write("acp request \(method) declined: \(params)")
                write(ACPCodec.response(id: id, result: ["outcome": ["outcome": "cancelled"]]))
            case .notification:
                break
            }
        }
    }
}
