import AppKit
import ApplicationServices
import SpacesCore
import SpacesBridge

struct LiveDisplay {
    let uuid: String
    let name: String
    let screen: NSScreen
    let spaces: DisplaySpaces
}

// AX timeouts are per object, not inherited from the application's AX element.
// Keep every potentially blocking IPC bounded, including child reads/actions.
enum BoundedAX {
    static func prepare(_ element: AXUIElement, timeout: Float = 0.3) -> Bool {
        AXUIElementSetMessagingTimeout(element, timeout) == .success
    }
    static func value(_ element: AXUIElement, _ key: String, timeout: Float = 0.3) -> CFTypeRef? {
        guard prepare(element, timeout: timeout) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success else { return nil }
        return result
    }
}

@MainActor
final class SystemAdapter {
    func inventory() throws -> [LiveDisplay] {
        guard SDAvailable(), let raw = SDReadSpaces() as? [[String: Any]] else {
            throw LayoutError.invalid("Les capacités privées nécessaires aux bureaux et fenêtres sont indisponibles sur cette version de macOS ou dans cette session. Aucun profil ne peut être appliqué. Lance l’app depuis Finder ; si le problème persiste, exporte le diagnostic.")
        }
        let screens = NSScreen.screens
        var descriptors: [RuntimeDisplayDescriptor] = []
        var result: [LiveDisplay] = []
        for screen in screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                throw LayoutError.invalid("Un écran n’a pas d’identifiant système. Reconnecte les écrans, puis réessaie.")
            }
            let displayID = number.uint32Value
            guard let uuidRef = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
                throw LayoutError.invalid("L’identité de l’écran \(screen.localizedName) est inaccessible. L’opération est arrêtée ; vérifie la disposition avant de réessayer.")
            }
            let uuid = CFUUIDCreateString(nil, uuidRef)! as String
            let builtIn = CGDisplayIsBuiltin(displayID) != 0
            descriptors.append(.init(identifier: uuid, builtIn: builtIn, mirrored: CGDisplayIsInMirrorSet(displayID) != 0))
            let matches = raw.filter { ($0["Display Identifier"] as? String) == uuid }
            let fallback = raw.filter { ($0["Display Identifier"] as? String) == "Main" }
            let candidates = matches.isEmpty && displayID == CGMainDisplayID() ? fallback : matches
            guard candidates.count == 1, let items = candidates[0]["Spaces"] as? [[String: Any]] else {
                throw LayoutError.invalid("Les bureaux de \(screen.localizedName) sont absents ou ambigus. Réessaie après la reconnexion de l’écran.")
            }
            let spaces = try readDesktops(items, displayName: screen.localizedName)
            result.append(LiveDisplay(uuid: uuid, name: screen.localizedName, screen: screen,
                spaces: .init(role: builtIn ? .builtIn : .external, desktops: spaces)))
        }
        if let issue = runtimeTopologyIssue(descriptors, separateSpaces: NSScreen.screensHaveSeparateSpaces) {
            throw LayoutError.invalid(issue)
        }
        let allSpaces = result.flatMap { $0.spaces.desktops }
        try validateDesktopIdentities(allSpaces)
        return result
    }

    func pref(_ key: String, domain: String) -> Any? {
        CFPreferencesAppSynchronize(domain as CFString)
        return CFPreferencesCopyAppValue(key as CFString, domain as CFString)
    }
    func setPref(_ key: String, value: Any?, domain: String) throws {
        CFPreferencesSetAppValue(key as CFString, value as CFPropertyList?, domain as CFString)
        guard CFPreferencesAppSynchronize(domain as CFString) else {
            throw LayoutError.invalid("Impossible d’enregistrer \(key). Les préférences macOS sont inaccessibles.")
        }
    }
    func snapshot() -> [String: Any] {
        var result: [String: Any] = ["version":1]
        for (domain, key) in [("com.apple.dock","persistent-apps"), ("com.apple.dock","mru-spaces"), ("com.apple.spaces","app-bindings")] {
            result[domain + "/" + key] = ["present": pref(key, domain: domain) != nil, "value": pref(key, domain: domain) ?? ""]
        }
        return result
    }
    func restore(_ snapshot: [String: Any]) throws {
        for composite in ["com.apple.dock/persistent-apps", "com.apple.dock/mru-spaces", "com.apple.spaces/app-bindings"] {
            guard let entry = snapshot[composite] as? [String:Any], entry["present"] is Bool, entry["value"] != nil else {
                throw LayoutError.invalid("Sauvegarde incomplète : \(composite).")
            }
        }
        for (domain, key) in [("com.apple.dock","persistent-apps"), ("com.apple.dock","mru-spaces"), ("com.apple.spaces","app-bindings")] {
            guard let entry = snapshot[domain + "/" + key] as? [String: Any], let present = entry["present"] as? Bool else {
                throw LayoutError.invalid("Sauvegarde incomplète : \(key).")
            }
            try setPref(key, value: present ? entry["value"] : nil, domain: domain)
        }
        try restartDock()
    }
    func validateTargets(_ resolved: [ResolvedRule]) throws {
        guard AXIsProcessTrusted() else { throw RuntimeSafetyFailure.accessibilityRequired }
        let currentDisplays = try inventory()
        for item in resolved {
            guard let desktops = currentDisplays.first(where: { $0.spaces.role == item.rule.screen })?.spaces.desktops,
                  runtimeTargetIsCurrent(item.target, desktopNumber: item.rule.desktop, desktops: desktops) else {
                throw LayoutError.invalid("Les bureaux ont changé depuis la préparation. Réapplique le profil ; aucune préférence n’a été modifiée.")
            }
        }
    }
    func configure(_ resolved: [ResolvedRule], previousIDs: [String], original: [String: Any]) throws {
        // Recheck at the mutation boundary, even if the caller resolved earlier.
        try validateTargets(resolved)
        let currentBindings = pref("app-bindings", domain: "com.apple.spaces") as? [String: String] ?? [:]
        let baseline = (original["com.apple.spaces/app-bindings"] as? [String: Any])?["value"] as? [String: String] ?? [:]
        let bindings = desktopAppBindings(resolved, previousIDs: previousIDs, current: currentBindings, baseline: baseline)
        let oldDock = pref("persistent-apps", domain: "com.apple.dock") as? [[String: Any]] ?? []
        let newDock = dockItems(rules: resolved.map(\.rule), existing: oldDock)
        try performAuthorizedRuntimeMutation(isTrusted: AXIsProcessTrusted) {
            try setPref("app-bindings", value: bindings, domain: "com.apple.spaces")
        }
        try performAuthorizedRuntimeMutation(isTrusted: AXIsProcessTrusted) {
            try setPref("mru-spaces", value: false, domain: "com.apple.dock")
        }
        try performAuthorizedRuntimeMutation(isTrusted: AXIsProcessTrusted) {
            try setPref("persistent-apps", value: newDock, domain: "com.apple.dock")
        }
        guard (pref("app-bindings", domain: "com.apple.spaces") as? [String: String]) == bindings else {
            throw LayoutError.invalid("macOS n’a pas conservé les affectations. La sauvegarde va être restaurée.")
        }
        try restartDock()
    }
    func restartDock() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["-u", NSUserName(), "Dock"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        do {
            let status = try runRuntimeProcess(process, timeout: 2)
            guard status == 0 || status == 1 else {
                throw LayoutError.invalid("Le redémarrage du Dock a échoué (code \(status)). Réessaie après avoir vérifié le Dock.")
            }
        } catch RuntimeProcessError.timedOut {
            throw LayoutError.invalid("Le redémarrage du Dock n’a pas répondu sous 2 secondes. Vérifie le Dock avant de réessayer.")
        }
        // Dock may not have been running (during login); its next start loads preferences.
    }
    func spaces(of window: UInt32) -> [UInt64] {
        (SDWindowSpaces(window) as? [NSNumber] ?? []).map(\.uint64Value)
    }
    func appsWithWindows(_ bundleIDs: Set<String>, isCurrent: () -> Bool = { true }) async -> Set<String> {
        let allWindows = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var result = Set<String>()
        for bundleID in bundleIDs {
            await Task.yield()
            guard !Task.isCancelled, isCurrent() else { return result }
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
                await Task.yield()
                guard !Task.isCancelled, isCurrent() else { return result }
                let hasSpaceWindow = allWindows.contains { info in
                    guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier,
                          (info[kCGWindowLayer as String] as? Int) == 0,
                          let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { return false }
                    // Includes other desktops and fullscreen windows, excludes dormant surfaces.
                    return !spaces(of: id).isEmpty
                }
                if hasSpaceWindow { result.insert(bundleID); break }
                // Accessibility also exposes minimized windows that may be absent
                // from the WindowServer inventory. Do not open a duplicate for them.
                if AXIsProcessTrusted() {
                    let axApp = AXUIElementCreateApplication(app.processIdentifier)
                    guard let windows = BoundedAX.value(axApp, kAXWindowsAttribute) as? [AXUIElement] else { continue }
                    let deadline = ProcessInfo.processInfo.systemUptime + 0.6
                    for window in windows {
                        await Task.yield()
                        guard !Task.isCancelled, isCurrent() else { return result }
                        guard ProcessInfo.processInfo.systemUptime < deadline else { break }
                        if (BoundedAX.value(window, kAXMinimizedAttribute) as? Bool) == true {
                            result.insert(bundleID); break
                        }
                    }
                    if result.contains(bundleID) { break }
                }
            }
        }
        return result
    }
    func moveWindows(_ items: [ResolvedRule], displays: [LiveDisplay], requiringWindows: Set<String> = [], isCurrent: () -> Bool) async -> MoveReport {
        let windows = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var report = MoveReport()
        do {
            let current = try inventory()
            guard Set(current.map(\.uuid)) == Set(displays.map(\.uuid)) else { throw CancellationError() }
            for item in items {
                guard let desktops = current.first(where: { $0.spaces.role == item.rule.screen })?.spaces.desktops,
                      runtimeTargetIsCurrent(item.target, desktopNumber: item.rule.desktop, desktops: desktops) else {
                    throw LayoutError.invalid("L’ordre des bureaux a changé. Réapplique le profil pour utiliser les nouveaux numéros.")
                }
            }
        } catch {
            report.failed = 1; report.lines.append("Placement interrompu : \(error.localizedDescription)"); return report
        }
        for item in items {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: item.rule.id)
            guard !apps.isEmpty || requiringWindows.contains(item.rule.id) else { continue }
            guard let display = displays.first(where: { $0.spaces.role == item.rule.screen }),
                  let number = display.screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                report.failed += 1; report.lines.append("\(item.rule.name) : écran cible indisponible."); continue
            }
            let targetFrame = CGDisplayBounds(number.uint32Value)
            var moved = 0; var failed = 0; var full = 0
            for app in apps {
                let owned = windows.filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0 }
                for window in owned {
                    await Task.yield()
                    guard !Task.isCancelled, isCurrent() else {
                        report.failed += 1; report.lines.append("Écrans ou automatisation modifiés : déplacement interrompu."); return report
                    }
                    guard let id = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
                    guard let membership = SDWindowSpaces(id) as? [NSNumber] else { failed += 1; continue }
                    let current = membership.map(\.uint64Value)
                    // AppKit also exposes dormant menu/utility surfaces at layer 0.
                    // They have no Space and are not displayed. Windows on another
                    // desktop still have membership and must remain in the move list.
                    if current.isEmpty {
                        if (window[kCGWindowIsOnscreen as String] as? Bool) == true { failed += 1 }
                        continue
                    }
                    if current.contains(where: { SDSpaceType($0) != 0 }) { full += 1; continue }
                    do {
                        try performAuthorizedRuntimeMutation(isTrusted: AXIsProcessTrusted) {
                            _ = positionWindow(id: id, pid: app.processIdentifier, info: window, on: display.screen)
                        }
                    } catch {
                        report.failed += 1; report.lines.append(error.localizedDescription); return report
                    }
                    await Task.yield()
                    guard !Task.isCancelled, isCurrent() else {
                        report.failed += 1; report.lines.append("Placement interrompu ; une fenêtre a peut-être déjà changé d’écran."); return report
                    }
                    if !current.contains(item.target.id) {
                        do {
                            let code = try performAuthorizedRuntimeMutation(isTrusted: AXIsProcessTrusted) {
                                SDMoveWindow(id, item.target.id)
                            }
                            if code != 0 { failed += 1; continue }
                        } catch {
                            report.failed += 1; report.lines.append(error.localizedDescription); return report
                        }
                    }
                    var verified = false
                    for _ in 0..<8 {
                        do { try await Task.sleep(for: .milliseconds(80)) }
                        catch { report.failed += 1; report.lines.append("Déplacement interrompu."); return report }
                        guard isCurrent() else { report.failed += 1; report.lines.append("Écrans modifiés : déplacement interrompu."); return report }
                        if windowPlacementIsVerified(spaceIDs: spaces(of: id), targetSpace: item.target.id,
                                                     frame: windowFrame(id), targetDisplay: targetFrame) { verified = true; break }
                    }
                    if verified { moved += 1 } else { failed += 1 }
                }
            }
            if requiringWindows.contains(item.rule.id) && moved + failed + full == 0 {
                report.failed += 1
                report.lines.append("\(item.rule.name) : ouverture demandée, mais aucune fenêtre disponible pour le placement. Termine son ouverture, puis réapplique le profil.")
                continue
            }
            report.verified += moved; report.failed += failed; report.skipped += full
            report.lines.append("\(item.rule.name) : \(moved) fenêtre\(moved > 1 ? "s" : "") placée\(moved > 1 ? "s" : "")" + (full > 0 ? ", \(full) en plein écran ignorée\(full > 1 ? "s" : "")" : "") + (failed > 0 ? ", \(failed) non vérifiée\(failed > 1 ? "s" : "") — vérifier Accessibilité et le bureau cible" : ""))
        }
        return report
    }
    private func positionWindow(id: UInt32, pid: pid_t, info: [String: Any], on screen: NSScreen) -> Bool {
        guard let bounds = info[kCGWindowBounds as String] as? [String: Any], let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
        let originHeight = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        let vf = screen.visibleFrame
        let area = CGRect(x: vf.minX, y: originHeight - vf.maxY, width: vf.width, height: vf.height)
        if area.contains(CGPoint(x: frame.midX, y: frame.midY)) { return true }
        guard AXIsProcessTrusted() else { return false }
        let axApp = AXUIElementCreateApplication(pid)
        guard let windows = BoundedAX.value(axApp, kAXWindowsAttribute) as? [AXUIElement] else { return false }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.6
        var matchingWindow: AXUIElement?
        for window in windows {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            guard BoundedAX.prepare(window) else { continue }
            var wid: UInt32 = 0
            if SDAXWindowID(window, &wid) == 0 && wid == id { matchingWindow = window; break }
        }
        guard let ax = matchingWindow, BoundedAX.prepare(ax) else { return false }
        var point = CGPoint(x: area.minX + max(0, (area.width - frame.width)/2), y: area.minY + max(0, (area.height - frame.height)/2))
        guard let position = AXValueCreate(.cgPoint, &point) else { return false }
        guard AXIsProcessTrusted() else { return false }
        return AXUIElementSetAttributeValue(ax, kAXPositionAttribute as CFString, position) == .success
    }
    private func windowFrame(_ id: UInt32) -> CGRect? {
        guard let windows = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let info = windows.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }),
              let bounds = info[kCGWindowBounds as String] as? [String: Any] else { return nil }
        return CGRect(dictionaryRepresentation: bounds as CFDictionary)
    }
    func diagnostic() -> String {
        let context = ["macOS \(ProcessInfo.processInfo.operatingSystemVersionString)", "API Spaces et déplacement : \(SDAvailable())", "Accessibilité : \(AXIsProcessTrusted())", "Espaces distincts : \(NSScreen.screensHaveSeparateSpaces)"]
        do {
            let displays = try inventory()
            return (context + displays.map { "\($0.name) — \($0.spaces.role.rawValue) — \($0.spaces.desktops.count) bureaux" }).joined(separator: "\n")
        } catch { return (context + ["Diagnostic : \(error.localizedDescription)"]).joined(separator: "\n") }
    }
}
