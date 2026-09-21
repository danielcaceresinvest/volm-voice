import Foundation

/// One transcriber result on the app's monotonic clock (seconds).
public struct TranscriptSegment: Equatable {
    public var start: Double
    public var end: Double
    public var text: String
    public var isFinal: Bool

    public init(start: Double, end: Double, text: String, isFinal: Bool) {
        self.start = start
        self.end = end
        self.text = text
        self.isFinal = isFinal
    }
}

/// Finalized phrases plus the one volatile phrase still being recognized.
public struct TranscriptBuffer {
    public private(set) var finals: [TranscriptSegment] = []
    public private(set) var volatile: TranscriptSegment?

    public init() {}

    public mutating func apply(_ segment: TranscriptSegment) {
        if segment.isFinal {
            finals.append(segment)
            if let v = volatile, v.start < segment.end { volatile = nil }
        } else {
            volatile = segment
        }
    }

    /// Text of every phrase that still had speech after `mark`.
    public func text(since mark: Double) -> String {
        var parts = finals.filter { $0.end > mark + 0.05 }.map(\.text)
        if let v = volatile, v.end > mark + 0.05 { parts.append(v.text) }
        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// A lone "." or an empty result is not pending speech.
    public var hasPendingVolatile: Bool { volatile.map { $0.text.contains(where: { $0.isLetter || $0.isNumber }) } ?? false }

    public mutating func prune(before time: Double) {
        finals.removeAll { $0.end < time }
    }
}

/// Energy-based voice activity with an adaptive noise floor.
public struct VoiceActivity {
    public private(set) var noiseFloor: Double = -55
    public private(set) var lastSpeechTime: Double = -1_000
    public private(set) var isSpeaking = false

    public init() {}

    public mutating func feed(db: Double, at time: Double) {
        if db < noiseFloor {
            noiseFloor += (db - noiseFloor) * 0.2
        } else {
            noiseFloor += (db - noiseFloor) * 0.002
        }
        noiseFloor = min(max(noiseFloor, -80), -30)
        let threshold = noiseFloor + (isSpeaking ? 6 : 10)
        if db > threshold {
            isSpeaking = true
            lastSpeechTime = time
        } else if time - lastSpeechTime > 0.3 {
            isSpeaking = false
        }
    }

    public func silence(at time: Double) -> Double { time - lastSpeechTime }
}
