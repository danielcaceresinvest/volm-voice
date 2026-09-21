import AppKit
import CoreText
import Foundation

enum Log {
    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/VOLM Voice", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("volm-voice.log")
    }()
    private static let queue = DispatchQueue(label: "studio.volm.voice.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}

struct Settings: Codable {
    var wakeWords = ["oye monica", "monica"]
    var voiceId = "com.apple.siri.natural.Luisa"
    var sessionKey = "agent:main:voz"
    var locale = "es_ES"
    var followUpSeconds = 8.0
    var followUpQuestionSeconds = 15.0
    var endOfUtteranceSilence = 1.5
    var viscosity = 0.45
    var turbulence = 0.55
    var reaction = 1.0
    var cut = false
    var wakeEnabled = true
    var pushToTalk = false
    var confirmSeconds = 20.0
    var briefingEnabled = false
    var briefingHour = 9
    var briefingMinute = 0
    var briefingPrompt = "Dame el resumen de la mañana: mi agenda de hoy, los correos importantes sin leer y el tiempo. Breve."
    /// Secret that `volm-voice://ask` and `volm-voice://say` links must carry, so a web page cannot talk to Mónica.
    var urlKey = ""

    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/VOLM Voice", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        wakeWords = try c.decodeIfPresent([String].self, forKey: .wakeWords) ?? d.wakeWords
        voiceId = try c.decodeIfPresent(String.self, forKey: .voiceId) ?? d.voiceId
        sessionKey = try c.decodeIfPresent(String.self, forKey: .sessionKey) ?? d.sessionKey
        locale = try c.decodeIfPresent(String.self, forKey: .locale) ?? d.locale
        followUpSeconds = try c.decodeIfPresent(Double.self, forKey: .followUpSeconds) ?? d.followUpSeconds
        followUpQuestionSeconds = try c.decodeIfPresent(Double.self, forKey: .followUpQuestionSeconds) ?? d.followUpQuestionSeconds
        endOfUtteranceSilence = try c.decodeIfPresent(Double.self, forKey: .endOfUtteranceSilence) ?? d.endOfUtteranceSilence
        viscosity = try c.decodeIfPresent(Double.self, forKey: .viscosity) ?? d.viscosity
        turbulence = try c.decodeIfPresent(Double.self, forKey: .turbulence) ?? d.turbulence
        reaction = try c.decodeIfPresent(Double.self, forKey: .reaction) ?? d.reaction
        cut = try c.decodeIfPresent(Bool.self, forKey: .cut) ?? d.cut
        wakeEnabled = try c.decodeIfPresent(Bool.self, forKey: .wakeEnabled) ?? d.wakeEnabled
        pushToTalk = try c.decodeIfPresent(Bool.self, forKey: .pushToTalk) ?? d.pushToTalk
        confirmSeconds = try c.decodeIfPresent(Double.self, forKey: .confirmSeconds) ?? d.confirmSeconds
        briefingEnabled = try c.decodeIfPresent(Bool.self, forKey: .briefingEnabled) ?? d.briefingEnabled
        briefingHour = try c.decodeIfPresent(Int.self, forKey: .briefingHour) ?? d.briefingHour
        briefingMinute = try c.decodeIfPresent(Int.self, forKey: .briefingMinute) ?? d.briefingMinute
        briefingPrompt = try c.decodeIfPresent(String.self, forKey: .briefingPrompt) ?? d.briefingPrompt
        urlKey = try c.decodeIfPresent(String.self, forKey: .urlKey) ?? d.urlKey
    }

    static func load() -> Settings {
        var s = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
        if s.urlKey.isEmpty { s.urlKey = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
        s.save()
        return s
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: Settings.url, options: .atomic)
        // The file holds the link secret: owner-only.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Settings.url.path)
    }
}

/// Suisse Int'l ships inside the app bundle; SwiftUI finds the faces by PostScript name.
enum Fonts {
    private(set) static var grotesk: String?
    private(set) static var mono: String?

    static func register() {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for file in files where ["otf", "ttf"].contains(file.pathExtension.lowercased()) {
            CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
            guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(file as CFURL) as? [CTFontDescriptor] else { continue }
            for d in descriptors {
                guard let name = CTFontDescriptorCopyAttribute(d, kCTFontNameAttribute) as? String else { continue }
                // Trial cuts of a typeface ship without the full Spanish set; the system faces are better than "monica".
                guard coversSpanish(CTFontCreateWithFontDescriptor(d, 14, nil)) else {
                    Log.write("font \(name) lacks Spanish glyphs, using the system font instead")
                    continue
                }
                if name.lowercased().contains("mono") { mono = name } else { grotesk = name }
            }
        }
        Log.write("fonts: grotesk=\(grotesk ?? "-") mono=\(mono ?? "-")")
    }
}

private func coversSpanish(_ font: CTFont) -> Bool {
    var chars = Array("áéíóúñü¿¡ÁÉÍÓÚÑ".utf16)
    var glyphs = [CGGlyph](repeating: 0, count: chars.count)
    return CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count)
}

enum Palette {
    static let ink = NSColor(srgbRed: 0x15 / 255, green: 0x14 / 255, blue: 0x12 / 255, alpha: 1)
    static let paper = NSColor(srgbRed: 0xE5 / 255, green: 0xE1 / 255, blue: 0xD7 / 255, alpha: 1)
    static let red = NSColor(srgbRed: 0xE2 / 255, green: 0x23 / 255, blue: 0x1A / 255, alpha: 1)
}
