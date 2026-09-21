import Foundation

/// Text helpers shared by wake-word matching, intent detection and the echo guard.
public enum VoiceText {
    /// Lowercased, accent-free, with every run of non-alphanumerics collapsed to one space.
    public static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es_ES")).lowercased()
        var out = ""
        var lastWasSpace = true
        for ch in folded {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastWasSpace = false
            } else if !lastWasSpace {
                out.append(" ")
                lastWasSpace = true
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    public static func words(_ text: String) -> [String] {
        normalize(text).split(separator: " ").map(String.init)
    }
}

public struct WakeMatch: Equatable {
    /// What was said after the wake word, with the original casing and punctuation.
    public let command: String
}

public struct WakeDetector {
    private let phrases: [[String]]

    public init(wakeWords: [String] = ["oye monica", "monica"]) {
        phrases = wakeWords
            .map { VoiceText.words($0) }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
    }

    /// Finds the last wake word in `text` and returns what follows it.
    public func match(_ text: String) -> WakeMatch? {
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let normalized = tokens.map { VoiceText.normalize($0) }
        var bestEnd: Int?
        for phrase in phrases where normalized.count >= phrase.count {
            for start in 0...(normalized.count - phrase.count) where Array(normalized[start..<start + phrase.count]) == phrase {
                let end = start + phrase.count
                if bestEnd == nil || end > bestEnd! { bestEnd = end }
            }
        }
        guard let end = bestEnd else { return nil }
        let rest = tokens[end...].joined(separator: " ")
        let leading = CharacterSet(charactersIn: ",.;:-—…").union(.whitespaces)
        let command = String(rest.drop(while: { ch in ch.unicodeScalars.allSatisfy { leading.contains($0) } }))
        return WakeMatch(command: command)
    }
}

public enum UtteranceIntent: Equatable {
    case stop
    case close
    case none
}

public enum IntentDetector {
    private static let stopPhrases: Set<String> = [
        "para", "parate", "para ya", "calla", "callate", "cancela", "cancelalo", "stop", "basta", "silencio", "vale para", "espera",
    ]
    private static let closePhrases: Set<String> = [
        "gracias", "muchas gracias", "vale gracias", "gracias eso es todo", "eso es todo", "nada mas", "nada mas gracias",
        "hasta luego", "adios", "ya esta", "ya esta gracias", "perfecto gracias",
    ]

    /// Only whole short utterances count, so "para mañana" or "gracias a ti por…" are not commands.
    public static func intent(of utterance: String) -> UtteranceIntent {
        var words = VoiceText.words(utterance)
        if words.first == "oye" { words.removeFirst() }
        if words.first == "monica" { words.removeFirst() }
        if words.last == "monica" { words.removeLast() }
        let phrase = words.joined(separator: " ")
        if stopPhrases.contains(phrase) { return .stop }
        if closePhrases.contains(phrase) { return .close }
        return .none
    }
}

public enum EchoGuard {
    /// True when most words of `heard` appear in what Mónica just said: the mic picked up her own voice.
    public static func isEcho(_ heard: String, of spoken: [String]) -> Bool {
        let heardWords = VoiceText.words(heard)
        guard heardWords.count >= 2 else { return false }
        let spokenWords = Set(spoken.flatMap { VoiceText.words($0) })
        guard !spokenWords.isEmpty else { return false }
        let hits = heardWords.filter { spokenWords.contains($0) }.count
        return Double(hits) / Double(heardWords.count) >= 0.6
    }
}
