import AppKit
import SpacesCore

@main struct AppStoreChecks {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ name: String) {
            checks += 1
            guard value() else { print("FAIL: \(name)"); exit(1) }
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SpacesDock-store-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at:folder) }
        let store = AppStore(directory:folder)
        check(store.profiles.count == 2 && store.profiles.allSatisfy { $0.rules.isEmpty }, "Fresh install has two empty profiles")
        store.selected = "solo"
        let app = AppRule(id:"com.example.app",name:"Example",path:"/Applications/Example.app")
        store.profiles[0].rules = [app]
        let disk = ConfigurationFile(url:store.configURL)
        let first = try disk.load()
        check(first.profiles[0].rules == [app], "Add autosaves immediately")
        check(!store.dirty && store.pendingApplication, "Saved changes still need Apply")
        check(store.shouldTerminate(), "Clean autosaved editor may quit")
        let reopened = AppStore(directory:folder)
        check(reopened.profiles[0].rules == [app], "Reopening preserves edits without Apply")
        store.profiles[0].rules[0].desktop = 2
        check(store.canUndoEdit, "Editing exposes undo")
        store.undoEdit()
        check(store.profiles[0].rules[0].desktop == 1, "Undo restores assignment")
        let undone = try disk.load()
        check(undone.profiles[0].rules[0].desktop == 1, "Undo is persisted")
        let validBytes = try Data(contentsOf:store.configURL)
        store.profiles[0].rules[0].desktop = 17
        check(store.dirty && store.error != nil, "Rejected write keeps the editor visibly unsaved")
        check(try! Data(contentsOf:store.configURL) == validBytes, "Rejected write preserves valid bytes")
        store.setAutomatic(true)
        check(!store.automatic, "Unsaved editor cannot activate automation")
        store.undoEdit()
        check(!store.dirty && store.error == nil, "Undo recovers from invalid edit")
        let corrupt = Data("{broken".utf8)
        try corrupt.write(to:store.configURL)
        store.profiles[0].rules[0].desktop = 3
        check(store.dirty && store.error != nil, "External corruption prevents autosave overwrite")
        check(try! Data(contentsOf:store.configURL) == corrupt, "Corrupt file remains recoverable")
        let damaged = AppStore(directory:folder)
        check(damaged.configurationUnavailable, "Damaged configuration opens recovery state")
        check(!damaged.automatic && !damaged.launchAllAtLogin, "Recovery does not start automations")
        print("\(checks) AppStore checks, 0 failures")
    }
}
