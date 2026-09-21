import AppKit
import SwiftUI
import VOLMVoiceCore

/// "Modo clase": the conversation in a big window for a projector, so a room can read along.
struct StageView: View {
    @ObservedObject var vm: IslandViewModel
    let orb: OrbModel
    let onTap: () -> Void
    let onAnswer: (Bool) -> Void

    private let paper = Color(nsColor: Palette.paper)
    private let red = Color(nsColor: Palette.red)

    private func mono(_ size: CGFloat) -> Font {
        Fonts.mono.map { Font.custom($0, size: size) } ?? .system(size: size, design: .monospaced)
    }

    private func grotesk(_ size: CGFloat) -> Font {
        Fonts.grotesk.map { Font.custom($0, size: size) } ?? .system(size: size, weight: .medium)
    }

    var body: some View {
        GeometryReader { geo in
            let unit = min(geo.size.width / 16, geo.size.height / 9)
            let column = min(geo.size.width * 0.84, unit * 13)
            VStack(spacing: unit * 0.32) {
                Spacer(minLength: 0)
                OrbView(model: orb)
                    .frame(width: unit * 2.6, height: unit * 2.6)
                    .contentShape(Circle())
                    .onTapGesture(perform: onTap)
                if !vm.subtitles.you.isEmpty {
                    Text(vm.subtitles.you)
                        .font(mono(unit * 0.26))
                        .foregroundStyle(paper.opacity(0.62))
                        .lineLimit(2)
                        .truncationMode(.head)
                        .frame(width: column)
                }
                if !vm.subtitles.her.isEmpty {
                    Text(vm.subtitles.her)
                        .font(grotesk(unit * 0.46))
                        .foregroundStyle(paper)
                        .lineLimit(5)
                        .truncationMode(.head)
                        .lineSpacing(unit * 0.08)
                        .minimumScaleFactor(0.7)
                        .frame(width: column)
                }
                if let card = vm.subtitles.card {
                    CardView(card: card, width: min(column, unit * 8), scale: max(1, unit / 42), onAnswer: onAnswer)
                }
                HStack(spacing: unit * 0.14) {
                    if let flavor = vm.subtitles.flavor, vm.state == .thinking {
                        Image(systemName: flavor.symbol)
                            .font(.system(size: unit * 0.2, weight: .semibold))
                            .foregroundStyle(paper)
                    } else {
                        Circle().fill(vm.state == .offline ? paper.opacity(0.3) : red).frame(width: unit * 0.12, height: unit * 0.12)
                    }
                    Text(vm.subtitles.status.uppercased())
                        .font(mono(unit * 0.2))
                        .kerning(unit * 0.03)
                        .foregroundStyle(paper.opacity(0.62))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .multilineTextAlignment(.center)
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(IslandMetrics.settle, value: vm.subtitles.card)
            .animation(IslandMetrics.settle, value: vm.subtitles.her.isEmpty)
        }
        .background(Color(nsColor: Palette.ink))
    }
}

@MainActor
final class StageController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let make: () -> StageView
    var onClose: (() -> Void)?

    init(make: @escaping () -> StageView) {
        self.make = make
    }

    var isOpen: Bool { window != nil }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 630),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Mónica"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.backgroundColor = Palette.ink
        w.appearance = NSAppearance(named: .darkAqua)
        w.collectionBehavior = [.fullScreenPrimary]
        w.isReleasedWhenClosed = false
        w.contentMinSize = NSSize(width: 480, height: 270)
        w.contentView = NSHostingView(rootView: make())
        w.delegate = self
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        onClose?()
    }
}

/// Every preference, editable without touching `config.json`.
struct SettingsView: View {
    @ObservedObject var model: AppModel

    private func row<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).frame(width: 190, alignment: .trailing).foregroundStyle(.secondary)
            content()
        }
    }

    private func slider(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, step: Double, unit: String) -> some View {
        row(label) {
            Slider(value: value, in: range, step: step)
            Text(String(format: step < 1 ? "%.2f%@" : "%.0f%@", value.wrappedValue, unit))
                .monospacedDigit()
                .frame(width: 52, alignment: .trailing)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Escucha").font(.headline)
            row("Palabras de activación") {
                TextField("monica, oye monica", text: Binding(
                    get: { model.prefs.wakeWords.joined(separator: ", ") },
                    set: { text in
                        let words = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        if !words.isEmpty { model.prefs.wakeWords = words }
                    }))
            }
            slider("Pausa que cierra tu frase", $model.prefs.endOfUtteranceSilence, 0.8...3, step: 0.1, unit: " s")
            slider("Sigue escuchando", $model.prefs.followUpSeconds, 3...20, step: 1, unit: " s")
            slider("Si ella pregunta", $model.prefs.followUpQuestionSeconds, 5...30, step: 1, unit: " s")
            slider("Espera un «¿lo hago?»", $model.prefs.confirmSeconds, 8...40, step: 1, unit: " s")

            Divider()
            Text("Esfera").font(.headline)
            slider("Viscosidad", $model.prefs.viscosity, 0...1, step: 0.01, unit: "")
            slider("Turbulencia", $model.prefs.turbulence, 0...1, step: 0.01, unit: "")
            slider("Reacción a la voz", $model.prefs.reaction, 0.3...2, step: 0.01, unit: "")
            row("Movimiento a cortes") { Toggle("", isOn: $model.prefs.cut).labelsHidden() }

            Divider()
            Text("Resumen de la mañana").font(.headline)
            row("Decirlo cada día") {
                Toggle("", isOn: $model.prefs.briefingEnabled).labelsHidden()
                Stepper(String(format: "%02d:%02d", model.prefs.briefingHour, model.prefs.briefingMinute),
                        onIncrement: { model.shiftBriefing(minutes: 15) }, onDecrement: { model.shiftBriefing(minutes: -15) })
                    .monospacedDigit()
                    .disabled(!model.prefs.briefingEnabled)
            }
            row("Qué le pido") {
                TextField("", text: $model.prefs.briefingPrompt, axis: .vertical).lineLimit(2...3)
            }
        }
        .padding(22)
        .frame(width: 560)
    }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(model: AppModel) {
        if window == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Ajustes de VOLM Voice"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(model: model))
            w.delegate = self
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
