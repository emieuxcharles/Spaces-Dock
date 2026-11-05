import AppKit
import SwiftUI
import SpacesBridge

@main
struct Entry {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--diagnose") {
            _ = NSApplication.shared
            print(SystemAdapter().diagnostic()); return
        }
        if let index = CommandLine.arguments.firstIndex(of:"--probe-host"), CommandLine.arguments.count > index + 1 {
            probeHost(path:CommandLine.arguments[index+1]); return
        }
        if CommandLine.arguments.contains("--probe-cross-process") { probeCrossProcess(); return }
        if CommandLine.arguments.contains("--probe-move") {
            probeMove(); return
        }
        SpacesDockApp.main()
    }
    @MainActor static func probeHost(path: String) {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect:NSRect(x:80,y:80,width:320,height:100),styleMask:[.titled],backing:.buffered,defer:false)
        window.title = "Spaces Dock — test interprocessus"; window.isReleasedWhenClosed = false
        window.orderFrontRegardless(); RunLoop.current.run(until:Date().addingTimeInterval(0.3))
        try? String(window.windowNumber).write(toFile:path,atomically:true,encoding:.utf8)
        RunLoop.current.run(until:Date().addingTimeInterval(15))
        window.close()
    }
    @MainActor static func probeCrossProcess() {
        _ = NSApplication.shared
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("spacesdock-probe-" + UUID().uuidString)
        let child = Process(); child.executableURL = URL(fileURLWithPath:CommandLine.arguments[0])
        child.arguments = ["--probe-host",path.path]
        do { try child.run() } catch { print(error); exit(2) }
        defer { if child.isRunning { child.terminate() }; try? FileManager.default.removeItem(at:path) }
        for _ in 0..<30 {
            if FileManager.default.fileExists(atPath:path.path) { break }
            RunLoop.current.run(until:Date().addingTimeInterval(0.1))
        }
        let system = SystemAdapter()
        guard let text = try? String(contentsOf:path,encoding:.utf8), let id = UInt32(text),
              let original = system.spaces(of:id).first,
              let target = try? system.inventory().flatMap({$0.spaces.desktops}).first(where:{$0.id != original}) else {
            print("CROSS PROCESS UNAVAILABLE"); return
        }
        let code = SDMoveWindow(id,target.id)
        RunLoop.current.run(until:Date().addingTimeInterval(0.6))
        let moved = system.spaces(of:id).contains(target.id)
        let back = SDMoveWindow(id,original)
        RunLoop.current.run(until:Date().addingTimeInterval(0.6))
        let returned = system.spaces(of:id).contains(original)
        print("CROSS PROCESS: outbound=\(moved), return=\(returned), codes=\(code)/\(back)")
    }
    @MainActor static func probeMove() {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let system = SystemAdapter()
        let window = NSWindow(contentRect:NSRect(x:80,y:80,width:360,height:100),styleMask:[.titled],backing:.buffered,defer:false)
        window.title = "Spaces Dock — fenêtre de test temporaire"
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        RunLoop.current.run(until:Date().addingTimeInterval(0.3))
        let id = UInt32(window.windowNumber)
        guard let original = system.spaces(of:id).first,
              let target = try? system.inventory().flatMap({$0.spaces.desktops}).first(where:{$0.id != original}) else {
            print("PROBE UNAVAILABLE: deux bureaux nécessaires"); window.close(); exit(2)
        }
        let code = SDMoveWindow(id,target.id)
        RunLoop.current.run(until:Date().addingTimeInterval(0.4))
        let outbound = system.spaces(of:id).contains(target.id)
        let backCode = SDMoveWindow(id,original)
        RunLoop.current.run(until:Date().addingTimeInterval(0.4))
        let returned = system.spaces(of:id).contains(original)
        window.close()
        print("PROBE: outbound=\(outbound), return=\(returned), codes=\(code)/\(backCode)")
        exit(outbound && returned ? 0 : 1)
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    let store = AppStore()
    func applicationDidFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let atLogin = event?.eventID == kAEOpenApplication && event?.paramDescriptor(forKeyword:keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        store.startAutomation(launchedAtLogin:atLogin)
    }
    func applicationShouldTerminate(_ sender:NSApplication) -> NSApplication.TerminateReply {
        store.shouldTerminate() ? .terminateNow : .terminateCancel
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool) -> Bool {
        sender.windows.first(where:{$0.canBecomeMain})?.makeKeyAndOrderFront(nil); return true
    }
}
struct SpacesDockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    private var store: AppStore { delegate.store }
    var body: some Scene {
        Window("Spaces Dock",id:"main") {
            ContentView().environmentObject(store)
        }.defaultSize(width:1080,height:820)
        .commands {
            SpacesDockSettingsCommands(store:store)
            CommandGroup(replacing:.newItem) {}
            SpacesDockEditCommands(store:store)
        }
        MenuBarExtra("Spaces Dock",systemImage:"rectangle.3.group") {
            MenuContent().environmentObject(store)
        }
    }
}
struct MenuContent: View {
    @EnvironmentObject var store:AppStore
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Text(store.topologyAvailable ? (store.activeID == "solo" ? "MacBook seul" : "Avec écran externe") : "Écrans indisponibles")
        Button("Ouvrir Spaces Dock") { openWindow(id:"main"); NSApp.activate(ignoringOtherApps:true) }
        Button("Appliquer le profil actif") { Task { await store.applyActive() } }.disabled(store.busy || store.configurationUnavailable || !store.topologyAvailable)
        if store.busy {
            Text(store.status)
            Button("Annuler l’opération") { store.cancelOperation() }
        }
        Button("Réglages…") { store.settingsRequested = true; openWindow(id:"main"); NSApp.activate(ignoringOtherApps:true) }
        Toggle("Adaptation automatique",isOn:Binding(get:{store.automatic},set:{store.setAutomatic($0)}))
            .disabled(store.busy || store.configurationUnavailable)
        Divider()
        Button("Quitter Spaces Dock") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

struct SpacesDockSettingsCommands: Commands {
    @ObservedObject var store: AppStore
    @Environment(\.openWindow) var openWindow
    var body: some Commands {
        CommandGroup(replacing:.appSettings) {
            Button("Réglages…") {
                openWindow(id:"main")
                NSApp.activate(ignoringOtherApps:true)
                store.settingsRequested = true
            }.keyboardShortcut(",")
        }
    }
}

struct SpacesDockEditCommands: Commands {
    @ObservedObject var store: AppStore
    var body: some Commands {
        CommandGroup(replacing:.saveItem) {}
        CommandGroup(replacing:.undoRedo) {
            Button("Annuler la dernière modification") { store.undoEdit() }
                .keyboardShortcut("z").disabled(!store.canUndoEdit || store.busy || store.configurationUnavailable)
        }
    }
}
