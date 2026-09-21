import AppKit
import Combine
import SwiftUI
import VOLMVoiceCore

final class IslandViewModel: ObservableObject {
    /// The island only shows while a conversation is going on; waiting and offline both rest behind the notch.
    static func isOpen(_ state: VoiceState) -> Bool { state != .idle && state != .offline }

    @Published var state: VoiceState = .offline {
        didSet {
            let wasOpen = Self.isOpen(oldValue), isOpen = Self.isOpen(state)
            if wasOpen != isOpen { animation = isOpen ? IslandMetrics.morph : IslandMetrics.close } else { animation = IslandMetrics.settle }
        }
    }
    /// How the next layout change moves: bouncy when opening, no overshoot when closing.
    private(set) var animation = IslandMetrics.settle
    @Published var subtitles = Subtitles(status: "Conectando")
    @Published var notchWidth: CGFloat = 0
    @Published var notchHeight: CGFloat = 0
}

enum IslandMetrics {
    /// The panel never resizes; the island grows and shrinks inside it.
    static let panelSize = CGSize(width: 580, height: 480)
    static let openWidth: CGFloat = 430
    /// At rest the island sits entirely behind the hardware notch, a little smaller so nothing peeks out.
    static let restInsetWidth: CGFloat = 12
    static let restInsetHeight: CGFloat = 3
    /// Opening bounces. Closing must not: any overshoot would pull the island in behind the notch.
    static let morph = Animation.spring(response: 0.48, dampingFraction: 0.72)
    static let close = Animation.smooth(duration: 0.42)
    static let settle = Animation.spring(response: 0.36, dampingFraction: 0.86)
}

/// The shape that hangs from the top of the screen: small concave ears where it meets the edge,
/// round convex corners at the bottom. Both radii animate.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let t = max(0, min(topRadius, rect.width / 4, rect.height))
        let b = max(0, min(bottomRadius, rect.height / 2, (rect.width - 2 * t) / 2))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t), control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY), control: CGPoint(x: rect.minX + t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b), control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

private struct BlurFade: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content
            .blur(radius: active ? 10 : 0)
            .opacity(active ? 0 : 1)
            .scaleEffect(active ? 0.86 : 1, anchor: .top)
    }
}

private extension AnyTransition {
    static var blurFade: AnyTransition {
        .modifier(active: BlurFade(active: true), identity: BlurFade(active: false))
    }
}

extension ToolFlavor {
    var symbol: String {
        switch self {
        case .web: return "globe"
        case .mail: return "envelope"
        case .calendar: return "calendar"
        case .drive: return "externaldrive"
        case .screen: return "eye"
        case .notes: return "note.text"
        case .music: return "music.note"
        case .files: return "doc"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .draw: return "scribble"
        case .memory: return "brain"
        case .generic: return "gearshape"
        }
    }
}

extension Card.Kind {
    var symbol: String {
        switch self {
        case .confirm: return "questionmark.circle"
        case .mail: return "envelope"
        case .event: return "calendar"
        case .music: return "music.note"
        case .note: return "note.text"
        case .file: return "doc"
        case .screen: return "eye"
        case .info: return "sparkle"
        }
    }
}

/// What Mónica puts on screen: the email before it goes out, the event she made, a yes/no question.
struct CardView: View {
    let card: Card
    let width: CGFloat
    var scale: CGFloat = 1
    let onAnswer: (Bool) -> Void

    private let paper = Color(nsColor: Palette.paper)
    private let red = Color(nsColor: Palette.red)

    private func mono(_ size: CGFloat) -> Font {
        Fonts.mono.map { Font.custom($0, size: size * scale) } ?? .system(size: size * scale, design: .monospaced)
    }

    private func grotesk(_ size: CGFloat) -> Font {
        Fonts.grotesk.map { Font.custom($0, size: size * scale) } ?? .system(size: size * scale)
    }

    private func answer(_ label: String, filled: Bool, yes: Bool) -> some View {
        Text(label.uppercased())
            .font(mono(9))
            .kerning(1.1)
            .foregroundStyle(paper)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8 * scale)
            .background(Capsule().fill(filled ? red : paper.opacity(0.12)))
            .contentShape(Capsule())
            .onTapGesture { onAnswer(yes) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10 * scale) {
            HStack(alignment: .top, spacing: 10 * scale) {
                Image(systemName: card.kind.symbol)
                    .font(.system(size: 14 * scale, weight: .medium))
                    .foregroundStyle(card.needsAnswer ? red : paper)
                    .frame(width: 18 * scale)
                VStack(alignment: .leading, spacing: 3 * scale) {
                    Text(card.title)
                        .font(grotesk(13))
                        .foregroundStyle(paper)
                        .lineLimit(2)
                    if !card.detail.isEmpty {
                        Text(card.detail)
                            .font(mono(10))
                            .foregroundStyle(paper.opacity(0.62))
                            .lineLimit(3)
                    }
                }
                Spacer(minLength: 0)
            }
            if card.needsAnswer {
                HStack(spacing: 8 * scale) {
                    answer("No", filled: false, yes: false)
                    answer("Sí, hazlo", filled: true, yes: true)
                }
            }
        }
        .multilineTextAlignment(.leading)
        .padding(12 * scale)
        .frame(width: width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14 * scale, style: .continuous).fill(paper.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 14 * scale, style: .continuous).stroke(paper.opacity(0.12), lineWidth: 1))
    }
}

struct IslandView: View {
    @ObservedObject var vm: IslandViewModel
    let orb: OrbModel
    let onTap: () -> Void
    let onAnswer: (Bool) -> Void
    let onSize: (CGSize) -> Void

    private let paper = Color(nsColor: Palette.paper)
    private let red = Color(nsColor: Palette.red)

    private func mono(_ size: CGFloat) -> Font {
        Fonts.mono.map { Font.custom($0, size: size) } ?? .system(size: size, design: .monospaced)
    }

    private func grotesk(_ size: CGFloat) -> Font {
        Fonts.grotesk.map { Font.custom($0, size: size) } ?? .system(size: size)
    }

    private var dotColor: Color {
        switch vm.state {
        case .offline: return paper.opacity(0.3)
        case .thinking, .listening: return paper
        default: return red
        }
    }

    /// Changes when the island needs another line, so height changes spring instead of jumping.
    private var layoutKey: Int {
        (vm.subtitles.you.isEmpty ? 0 : 1) + (vm.subtitles.you.count / 52) * 2 + (vm.subtitles.her.isEmpty ? 0 : 100) + (vm.subtitles.her.count / 40) * 200
            + (vm.subtitles.card.map { 10_000 + ($0.needsAnswer ? 10_000 : 0) + $0.detail.count / 40 * 20_000 } ?? 0)
    }

    var body: some View {
        let hasNotch = vm.notchHeight > 0
        let barHeight = hasNotch ? vm.notchHeight : 0
        let closedWidth = hasNotch ? max(40, vm.notchWidth - IslandMetrics.restInsetWidth) : 120
        let closedHeight = hasNotch ? max(0, vm.notchHeight - IslandMetrics.restInsetHeight) : 0
        let open = IslandViewModel.isOpen(vm.state)
        let orbSize: CGFloat = open ? 60 : 8
        let topRadius: CGFloat = open ? 12 : 7
        let textWidth = IslandMetrics.openWidth - 2 * topRadius - 44

        VStack(spacing: 0) {
            Color.clear.frame(height: open ? barHeight : closedHeight)
            if open {
                VStack(spacing: 8) {
                    Color.clear.frame(width: 60, height: 66)
                    if !vm.subtitles.you.isEmpty {
                        Text(vm.subtitles.you)
                            .font(mono(11))
                            .foregroundStyle(paper.opacity(0.62))
                            .lineLimit(2)
                            .truncationMode(.head)
                            .frame(width: textWidth)
                            .transition(.blurFade)
                    }
                    if !vm.subtitles.her.isEmpty {
                        Text(vm.subtitles.her)
                            .font(grotesk(15))
                            .foregroundStyle(paper)
                            .lineLimit(4)
                            .truncationMode(.head)
                            .lineSpacing(2)
                            .frame(width: textWidth)
                            .transition(.blurFade)
                    }
                    if let card = vm.subtitles.card {
                        CardView(card: card, width: textWidth, onAnswer: onAnswer)
                            .padding(.vertical, 2)
                            .transition(.blurFade)
                    }
                    HStack(spacing: 6) {
                        if let flavor = vm.subtitles.flavor, vm.state == .thinking {
                            Image(systemName: flavor.symbol)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(paper)
                                .transition(.blurFade)
                        } else {
                            Circle().fill(dotColor).frame(width: 5, height: 5)
                        }
                        Text(vm.subtitles.status.uppercased())
                            .font(mono(9))
                            .kerning(1.1)
                            .foregroundStyle(paper.opacity(0.62))
                            .lineLimit(1)
                    }
                    .frame(width: textWidth)
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 18)
                .transition(.blurFade)
            }
        }
        .frame(width: open ? IslandMetrics.openWidth : closedWidth)
        .background(Color.black)
        .clipShape(NotchShape(topRadius: topRadius, bottomRadius: open ? 32 : 11))
        .overlay(alignment: .top) {
            // At rest the orb hides inside the notch; it grows out of it as the island opens.
            OrbView(model: orb)
                .frame(width: orbSize, height: orbSize)
                .padding(.top, open ? barHeight + 4 : max(0, (closedHeight - orbSize) / 2))
                .opacity(open ? 1 : 0)
        }
        .background(alignment: .top) {
            // The resting shape is always there, so the island can never look smaller than the notch.
            NotchShape(topRadius: 7, bottomRadius: 11)
                .fill(Color.black)
                .frame(width: closedWidth, height: closedHeight)
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .animation(vm.animation, value: open ? layoutKey : -1)
        .frame(width: IslandMetrics.panelSize.width, height: IslandMetrics.panelSize.height, alignment: .top)
    }
}

final class IslandPanel: NSPanel {
    init(content: NSView) {
        super.init(contentRect: NSRect(origin: .zero, size: IslandMetrics.panelSize),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        contentView = content
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Pins a fixed transparent panel to the top of the notch screen. The island animates inside it;
/// the panel only takes clicks while the pointer is over the island itself.
@MainActor
final class IslandController {
    let vm: IslandViewModel
    private var panel: IslandPanel!
    private var islandSize: CGSize = .zero
    private var mouseTimer: Timer?
    private var bag = Set<AnyCancellable>()

    init(vm: IslandViewModel, orb: OrbModel, onTap: @escaping () -> Void, onAnswer: @escaping (Bool) -> Void) {
        self.vm = vm
        let view = IslandView(vm: vm, orb: orb, onTap: onTap, onAnswer: onAnswer) { [weak self] size in
            MainActor.assumeIsolated { self?.islandSize = size }
        }
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: IslandMetrics.panelSize)
        panel = IslandPanel(content: hosting)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.layout() } }
            .store(in: &bag)
        mouseTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackPointer() }
        }
        layout()
    }

    private func screen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    func layout() {
        guard let screen = screen() else { return }
        let notchH = screen.safeAreaInsets.top
        var notchW: CGFloat = 0
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea { notchW = max(0, r.minX - l.maxX) }
        if vm.notchHeight != notchH { vm.notchHeight = notchH }
        if vm.notchWidth != notchW { vm.notchWidth = notchW }
        Log.write("island: notch \(notchW)x\(notchH) on \(screen.frame.size)")
        let top = notchH > 0 ? screen.frame.maxY : screen.visibleFrame.maxY
        let size = IslandMetrics.panelSize
        let frame = NSRect(x: screen.frame.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func logDiagnostics() {
        Log.write("island: visible=\(panel.isVisible) onActiveSpace=\(panel.isOnActiveSpace) occluded=\(!panel.occlusionState.contains(.visible)) frame=\(panel.frame) level=\(panel.level.rawValue) alpha=\(panel.alphaValue) islandSize=\(islandSize) state=\(vm.state.rawValue) content=\(panel.contentView?.frame ?? .zero)")
    }

    private var rescues = 0

    /// Nothing renders while the panel is off the active Space, so put it back if that ever happens.
    private func keepOnScreen() {
        if panel.isOnActiveSpace && panel.isVisible {
            rescues = 0
            return
        }
        guard rescues < 3 else { return }
        rescues += 1
        Log.write("island: off the active space, bringing it back (\(rescues)/3)")
        panel.orderFrontRegardless()
    }

    private func trackPointer() {
        keepOnScreen()
        let frame = panel.frame
        let island = NSRect(x: frame.midX - islandSize.width / 2, y: frame.maxY - islandSize.height,
                            width: islandSize.width, height: islandSize.height)
        let inside = island.contains(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
    }
}
