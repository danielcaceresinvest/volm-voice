import Foundation

/// Something Mónica wants on screen next to her words: the email she is about to send,
/// the event she created, the song that plays. She writes it as `[[tarjeta: tipo | título | detalle]]`.
public struct Card: Equatable {
    public enum Kind: String {
        case confirm, mail, event, music, note, file, screen, info
    }

    public var kind: Kind
    public var title: String
    public var detail: String

    public init(kind: Kind, title: String, detail: String = "") {
        self.kind = kind
        self.title = title
        self.detail = detail
    }

    /// A confirm card waits for a yes or a no before she acts.
    public var needsAnswer: Bool { kind == .confirm }

    static func kind(named name: String) -> Kind {
        switch VoiceText.normalize(name) {
        case "confirmar", "confirmacion", "confirm": return .confirm
        case "correo", "email", "mail": return .mail
        case "evento", "agenda", "calendario", "event": return .event
        case "musica", "cancion", "music": return .music
        case "nota", "recordatorio", "note": return .note
        case "archivo", "documento", "file": return .file
        case "pantalla", "screen": return .screen
        default: return .info
        }
    }

    /// Parses the inside of `[[…]]`. Returns nil when it is not a card, so the text is spoken as written.
    static func parse(_ body: String) -> Card? {
        guard let colon = body.firstIndex(of: ":") else { return nil }
        let head = VoiceText.normalize(String(body[..<colon]))
        guard head == "tarjeta" || head == "card" else { return nil }
        let parts = body[body.index(after: colon)...].split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count >= 2, !parts[1].isEmpty else { return nil }
        return Card(kind: kind(named: parts[0]), title: parts[1], detail: parts.dropFirst(2).filter { !$0.isEmpty }.joined(separator: " · "))
    }
}

/// Pulls `[[tarjeta: …]]` directives out of the streamed reply, so they reach the screen and never the voice.
public struct DirectiveFilter {
    private var held = ""
    /// A directive longer than this is not one; it is released as ordinary text.
    public var maxLength = 600

    public init() {}

    public mutating func reset() { held = "" }

    public mutating func feed(_ chunk: String) -> (text: String, cards: [Card]) {
        held += chunk
        return drain(final: false)
    }

    public mutating func flush() -> (text: String, cards: [Card]) {
        drain(final: true)
    }

    private mutating func drain(final: Bool) -> (text: String, cards: [Card]) {
        var text = ""
        var cards: [Card] = []
        while let open = held.range(of: "[[") {
            text += held[..<open.lowerBound]
            let after = held[open.upperBound...]
            if let close = after.range(of: "]]") {
                let body = String(after[..<close.lowerBound])
                if let card = Card.parse(body) { cards.append(card) } else { text += "[[\(body)]]" }
                held = String(after[close.upperBound...])
            } else if final || after.count > maxLength {
                text += held[open.lowerBound...]
                held = ""
            } else {
                held = String(held[open.lowerBound...])
                return (text, cards)
            }
        }
        // A lone "[" at the end may be the first half of "[[".
        if !final, held.hasSuffix("[") {
            text += held.dropLast()
            held = "["
        } else {
            text += held
            held = ""
        }
        return (text, cards)
    }
}

/// What a running tool is about, so the island can say something better than "Trabajando".
public enum ToolFlavor: String, Equatable {
    case web, mail, calendar, drive, screen, notes, music, files, code, draw, memory, generic

    public var status: String {
        switch self {
        case .web: return "Consultando la web"
        case .mail: return "Con tu correo"
        case .calendar: return "Mirando tu agenda"
        case .drive: return "Buscando en Drive"
        case .screen: return "Mirando tu pantalla"
        case .notes: return "Con tus notas"
        case .music: return "Apple Music"
        case .files: return "Con tus archivos"
        case .code: return "Programando"
        case .draw: return "Dibujando"
        case .memory: return "Haciendo memoria"
        case .generic: return "Trabajando en tu Mac"
        }
    }

    private static let keywords: [(ToolFlavor, [String])] = [
        (.mail, ["gog gmail", "gmail", "himalaya", "mail "]),
        (.calendar, ["gog calendar", "calendar", "icalbuddy"]),
        (.drive, ["gog drive", "gog docs", "gog sheets", "drive "]),
        (.screen, ["peekaboo", "screencapture", "screenshot", "mcp__openclaw__computer", "get_window_state", "list_windows"]),
        (.notes, ["memo ", "remindctl", "apple notes", "reminders", "notion"]),
        (.music, ["\"music\"", "application \\\"music\\\"", "apple music", "open -a music"]),
        (.code, ["coding-agent", "claude -p", "codex ", "opencode", "git ", "npm ", "swift build"]),
        (.draw, ["canvas", "diagram", "excalidraw", "meme"]),
        (.memory, ["memory_search", "memory_get", "memory"]),
        (.web, ["web_fetch", "web_search", "wttr.in", "browser", "curl ", "http"]),
        (.files, ["summarize", "nano-pdf", "mdfind", "find ", "ls ", "cat ", "cp ", "mv ", "touch ", "open "]),
    ]

    /// Reads the ACP tool kind and title ("mcp__openclaw__exec: command: gog gmail send …").
    public static func classify(kind: String?, title: String?) -> ToolFlavor? {
        let t = (title ?? "").lowercased()
        for (flavor, words) in keywords where words.contains(where: { t.contains($0) }) { return flavor }
        switch kind {
        case "fetch", "search": return .web
        case "read", "edit", "delete", "move": return .files
        case "execute": return .generic
        default: return nil
        }
    }
}
