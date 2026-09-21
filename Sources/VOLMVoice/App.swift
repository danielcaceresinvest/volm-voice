import AppKit
import SwiftUI

@main
struct VOLMVoiceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            Text("Mónica: \(model.stateLabel)")
            Divider()
            Button("Hablar con Mónica") { model.talkNow() }
            Button("Parar") { model.stopNow() }
            Divider()
            Toggle("Escuchar «Mónica»", isOn: $model.wakeEnabled)
            Toggle("Mantener ⌥ derecha para hablar", isOn: $model.pushToTalk)
            Toggle("Abrir al iniciar sesión", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            Divider()
            Toggle("Modo clase (pantalla grande)", isOn: Binding(get: { model.stageOpen }, set: { _ in model.toggleStage() }))
            Divider()
            Button("Reconectar con OpenClaw") { model.reconnect() }
            Button("Ajustes…") { model.openSettings() }
            Button("Ver registro") { model.openLog() }
            Divider()
            Button("Salir de VOLM Voice") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: "waveform.circle")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.start() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { urls.forEach { AppModel.shared.open($0) } }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.shutdown() }
    }
}
