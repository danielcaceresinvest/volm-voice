import Foundation

/// Turns a streamed markdown reply into clean sentences that can be spoken one by one.
public struct SentenceSplitter {
    public static let codeNotice = "Te lo dejo en pantalla."

    private var buffer = ""
    private var inCodeFence = false
    private var announcedCode = false
    public var minLength = 14
    public var softLimit = 200

    public init() {}

    public mutating func reset() {
        buffer = ""
        inCodeFence = false
        announcedCode = false
    }

    public mutating func feed(_ chunk: String) -> [String] {
        buffer += chunk
        return drain(final: false)
    }

    public mutating func flush() -> [String] {
        drain(final: true)
    }

    private mutating func drain(final: Bool) -> [String] {
        var out: [String] = []
        while true {
            if inCodeFence {
                guard let close = buffer.range(of: "```") else {
                    buffer = final ? "" : String(buffer.suffix(2))
                    break
                }
                buffer = String(buffer[close.upperBound...])
                inCodeFence = false
                continue
            }
            if let open = buffer.range(of: "```") {
                out += Self.split(String(buffer[..<open.lowerBound]), final: true, minLength: minLength, softLimit: softLimit).sentences
                if !announcedCode {
                    out.append(Self.codeNotice)
                    announcedCode = true
                }
                buffer = String(buffer[open.upperBound...])
                inCodeFence = true
                continue
            }
            break
        }
        let result = Self.split(buffer, final: final, minLength: minLength, softLimit: softLimit)
        buffer = result.rest
        return (out + result.sentences).map(Self.clean).filter { !$0.isEmpty }
    }

    static func split(_ text: String, final: Bool, minLength: Int, softLimit: Int) -> (sentences: [String], rest: String) {
        var sentences: [String] = []
        let chars = Array(text)
        var start = 0
        var i = 0
        while i < chars.count {
            let c = chars[i]
            var boundary = false
            if c == "\n" {
                boundary = true
            } else if ".!?…;:".contains(c) {
                if i + 1 < chars.count {
                    boundary = chars[i + 1].isWhitespace
                } else {
                    boundary = final
                }
            }
            if boundary {
                let candidate = String(chars[start...i])
                if clean(candidate).count >= minLength || c == "\n" && clean(candidate).isEmpty {
                    sentences.append(candidate)
                    start = i + 1
                }
            }
            i += 1
        }
        var rest = start < chars.count ? String(chars[start...]) : ""
        if !final, rest.count > softLimit, let comma = rest.range(of: ", ", options: .backwards) {
            sentences.append(String(rest[..<comma.lowerBound]) + ",")
            rest = String(rest[comma.upperBound...])
        }
        if final, !clean(rest).isEmpty {
            sentences.append(rest)
            rest = ""
        }
        return (sentences, rest)
    }

    private static let linkRegex = try! NSRegularExpression(pattern: #"\[([^\]]*)\]\([^)]*\)"#)
    private static let urlRegex = try! NSRegularExpression(pattern: #"https?://\S+"#)
    private static let bulletRegex = try! NSRegularExpression(pattern: #"^\s*(?:[-*•>]+|\d+[.)])\s+"#)
    private static let headingRegex = try! NSRegularExpression(pattern: #"^\s*#{1,6}\s*"#)

    /// Markdown and URLs are for the screen; the voice gets plain words.
    public static func clean(_ sentence: String) -> String {
        let lines = sentence.components(separatedBy: "\n").map(cleanLine).filter { !$0.isEmpty }
        var s = ""
        for line in lines {
            if s.isEmpty {
                s = line
            } else {
                s += ".!?…;:,".contains(s.last!) ? " " + line : ", " + line
            }
        }
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        s = s.trimmingCharacters(in: .whitespaces)
        guard s.contains(where: { $0.isLetter || $0.isNumber }) else { return "" }
        return s
    }

    private static func cleanLine(_ line: String) -> String {
        var s = line
        s = replace(linkRegex, in: s, with: "$1")
        s = replace(urlRegex, in: s, with: "")
        s = replace(headingRegex, in: s, with: "")
        s = replace(bulletRegex, in: s, with: "")
        for token in ["**", "__", "`", "*", "|"] { s = s.replacingOccurrences(of: token, with: "") }
        s = String(String.UnicodeScalarView(s.unicodeScalars.filter { !($0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x2000)) }))
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func replace(_ regex: NSRegularExpression, in s: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }
}
